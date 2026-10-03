// lexer.y — tokenize a Y source string into a list of token maps.
// Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
// Token types: id, num, str, bstr, char, op, punct, kw, eof, and ferr -- a
// malformed literal (a broken f-string, lex_fstring; a radix prefix without
// digits), v its error message.

// A token (see above); and a read position in a string, the cursor of
// the small readers outside the lexer (native.y's std pack and type
// decoders, pkg.y's y.toml reader).
type Tok = { t: str, v: str, line: long, col: long };
type Cursor = { s: str, p: long };

// NOTE: short underscore-free names (isdigit/isalpha/...) — see below.
def isdigit(c: byte) -> bool {
    c >= c'0' && c <= c'9'
};

// An upper-case letter.
def isupper(c: byte) -> bool {
    c >= c'A' && c <= c'Z'
};

// A lower-case letter.
def islower(c: byte) -> bool {
    c >= c'a' && c <= c'z'
};

def isalpha(c: byte) -> bool {
    // word chars: letters AND underscore (chr(95)) AND digits — Y words
    // like "t0"/"r64" contain digits, which is why the scan after the first
    // character is isalnum (letters + digits + "_"). The C twin's isalpha
    // /isalnum are the same two tests (src/c/lexer.c), so both lexers split
    // identifiers identically.
    islower(c) || isupper(c) || c == c'_' || isdigit(c)
};

def isalnum(c: byte) -> bool {
    isdigit(c) || isalpha(c)
};

// Digit of a radix literal (0x.. / 0b..), including `_` separators.
// Digit of a radix literal (0x.. / 0b..), including `_` separators.
def is_radix_ch(c: byte, radix: long) -> bool {
    if ( c == c'_') { true }
    else if (radix == 2) { c == c'0' || c == c'1' }
    else { isdigit(c) || (c >= c'a' && c <= c'f') || (c >= c'A' && c <= c'F') }
};

// A decimal literal's text without its `_` digit separators: its num token
// carries this, so whatever reads the literal (tonum, norm_num, the float
// helpers) sees plain digits. A radix literal keeps them (norm_num skips
// them).
def strip_seps(s: str) -> str {
    if (index_of(s, "_") < 0) { s } else { join(split(s, "_"), "") }
};

// A space, tab, newline or carriage return.
def isspace(c: byte) -> bool {
    c == c' ' || c == c'\t' || c == c'\n' || c == c'\r'
};

// NOTE: these predicates keep the flat C spellings isdigit/isupper/islower/
// isalpha/isalnum/isspace/ispunct because <ctype.h> reserves all seven as
// builtin names: the C twin has to rename them (src/c/lexer.h maps each to a
// y_lex_* symbol), and both copies must agree on the Y spelling at the call
// sites. The old companion rule — "avoid underscores, the other lexer stops
// at them" — no longer holds: isalpha above takes "_", and so does the C
// twin's, so a name like is_radix_ch lexes as one identifier in both.

// is c one of the single-char punctuation symbols?
// One of the nine punctuation characters Y uses.
def ispunct(c: byte) -> bool {
    c == c'(' || c == c')' || c == c'{' || c == c'}' || c == c'[' ||
    c == c']' || c == c',' || c == c';' || c == c':'
};

// Scan a quoted literal at src[i] (a `"` or `'` quote): returns the
// decoded text and the position just past the closing quote. Escapes:
// \n \t \r, \xHH, and `\<c>` drops the backslash (the Y literal rules).
def lex_quoted(src: str, i: long, line: long, col: long) -> { text: str, end: long, line: long, col: long } {
    let q = src[i:i + 1];
    let n = len(src);
    i = i + 1;
    col = col + 1;
    let start = i;
    let open = true;
    let closed = false;
    let hasesc = false;
    while (open) {
        if (i < n) {
            let ch = src[i:i + 1];
            if (ch == "\\") { hasesc = true; i = i + 2; col = col + 2; }
            else if (ch == q) { open = false; closed = true; }
            else {
                if (ch == "\n") { line = line + 1; col = 1; }
                else { col = col + 1; };
                i = i + 1;
            };
        } else { open = false; };
    };
    if (closed) {
    } else {
        // ran off the end with the quote still open
        puts("error: unterminated string literal\n");
        exit(1);
    };
    let raw = src[start:i];
    i = i + 1;  // skip closing quote
    col = col + 1;
    let buf = raw;
    if (hasesc) {
        buf = unescape(raw, false);
    };
    { text: buf, end: i, line: line, col: col }
};

// A literal's text from its raw source: \n \t \r, \xHH, and `\<c>` drops
// the backslash (the Y literal rules). In an f-string (`braces`) `{{` and
// `}}` are one brace each -- fstr_walk lets no single brace through.
def unescape(raw: str, braces: bool) -> str {
    // a chunk list + join (O(n))
    let chunks: [str] = [];
    let k = 0;
    let rn = len(raw);
    while (k < rn) {
        let rc = raw[k:k + 1];
        if (rc == "\\") {
            let esc = raw[k + 1:k + 2];
            if (esc == "n") { chunks += "\n"; k = k + 2; }
            else if (esc == "t") { chunks += "\t"; k = k + 2; }
            else if (esc == "r") { chunks += "\r"; k = k + 2; }
            else if (esc == "x") {
                // \xHH -- two hex digits
                let h1 = hexvalx(raw[k + 2:k + 3]);
                let h2 = hexvalx(raw[k + 3:k + 4]);
                if (h1 >= 0 && h2 >= 0) {
                    chunks += chr(h1 * 16 + h2);
                    k = k + 4;
                } else {
                    chunks += esc;
                    k = k + 2;
                };
            }
            else { chunks += esc; k = k + 2; };
        } else if (braces && (rc == "{" || rc == "}")) {
            chunks += rc;
            k = k + 2;
        } else {
            chunks += rc;
            k = k + 1;
        };
    };
    join(chunks, "")
};

// ── f-strings ────────────────────────────────────────────────────────────
// f"x = {x}, mean {total / n:.2f}" -- text with fields in braces. A field
// is one expression, then optionally `:` and a format spec running to the
// closing brace (types.y fmt_spec). `{{` and `}}` are literal braces, and
// a backslash escapes as in any literal (`\{` too). The expression ends at
// the first `}` or `:` outside brackets and literals -- a `:` closing a
// `c ? a : b` excepted -- so strings, slices and records need no escaping
// in it: f"{d["k"]}", f"{s[1:3]}", f"{n == 1 ? "" : "s"}".

// A byte of an identifier-shaped word (isalnum, on a byte).
def wordbyte(c: long) -> bool {
    isalpha(c)
};

// Just past the literal whose opening quote is src[q] (a backslash escapes
// the byte after it); len(src) when it never closes.
def lit_end(src: str, q: long) -> long {
    let n = len(src);
    let qc = byte_at(src, q);
    let i = q + 1;
    let end = n;
    let open = true;
    while (open && i < n) {
        let c = byte_at(src, i);
        if (c == c'\\') { i = i + 2; }
        else if (c == qc) { end = i + 1; open = false; }
        else { i = i + 1; };
    };
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
        let c = byte_at(src, i);
        if (c == c'"' || c == c'\'') {
            if (c == c'"' && i > lo && byte_at(src, i - 1) == 102 && (i - 1 == lo || !wordbyte(byte_at(src, i - 2)))) {
                // a nested f"..."
                i = fstr_walk(src, i).end;
            } else {
                i = lit_end(src, i);
            };
        } else if (c == c'(' || c == c'[' || c == c'{') {
            depth = depth + 1;
            i = i + 1;
        } else if (depth > 0) {
            if (c == c')' || c == c']' || c == c'}') { depth = depth - 1; }
            i = i + 1;
        } else if (c == c'?') {
            tern = tern + 1;
            i = i + 1;
        } else if (c == c':' && tern > 0) {
            tern = tern - 1;
            i = i + 1;
        } else if (c == c'}' || c == c':' || c == c',' || c == c';' || c == c')' || c == c']') {
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
        let c = byte_at(src, i);
        blank = isspace(c);
        i = i + 1;
    };
    blank
};

// Walk the f-string whose opening quote is src[q]: where it ends (past the
// closing quote), what is wrong with it ("" when nothing is) and where, and
// its fields, four numbers each: the expression is src[lo:hi], the spec
// src[slo:shi] (both -1 without a `:`). The lexer lowers what this finds
// (lex_fstring) and native.y's splice scan reads the same fields as code
// (words_scan), so the two always agree. A broken f-string ends where a
// plain literal would.
def fstr_walk(src: str, q: long) -> { end: long, err: str, at: long, fields: [long] } {
    let n = len(src);
    let fields: [long] = [];
    let err = "";
    let at = q;
    let i = q + 1;
    let open = true;
    while (open) {
        if (i >= n) {
            err = "unterminated f-string";
            open = false;
        } else {
            let c = byte_at(src, i);
            if (c == c'\\') {
                i = i + 2;
            } else if (c == c'"') {
                i = i + 1;
                open = false;
            } else if ((c == c'{' || c == c'}') && i + 1 < n && byte_at(src, i + 1) == c) {
                i = i + 2;
            } else if (c == c'}') {
                err = "single '}' in an f-string (a literal brace is '}}')";
                at = i;
                open = false;
            } else if (c == c'{') {
                let lo = i + 1;
                let hi = fstr_expr_end(src, lo);
                let hc = 0;
                if (hi < n) { hc = byte_at(src, hi); }
                if (hc != c'}' && hc != c':') {
                    if (hi >= n) {
                        err = "unterminated f-string field";
                        at = i;
                    } else {
                        err = "an f-string field is one expression, got '" + src[hi:hi + 1] + "'";
                        at = hi;
                    };
                    open = false;
                } else if (fstr_blank(src, lo, hi)) {
                    err = "empty f-string field";
                    at = i;
                    open = false;
                } else if (hc == c'}') {
                    fields += lo;
                    fields += hi;
                    fields += 0 - 1;
                    fields += 0 - 1;
                    i = hi + 1;
                } else {
                    // the spec: up to the closing brace
                    let e = hi + 1;
                    while (e < n && byte_at(src, e) != 125 && byte_at(src, e) != 123 && byte_at(src, e) != 34) {
                        e = e + 1;
                    };
                    if (e < n && byte_at(src, e) == 125) {
                        fields += lo;
                        fields += hi;
                        fields += hi + 1;
                        fields += e;
                        i = e + 1;
                    } else {
                        if (e < n && byte_at(src, e) == 123) {
                            err = "a format spec cannot hold '{'";
                            at = e;
                        } else {
                            err = "unterminated f-string field";
                            at = i;
                        };
                        open = false;
                    };
                };
            } else {
                i = i + 1;
            };
        };
    };
    let end = i;
    if (err != "") { end = lit_end(src, q); }
    { end: end, err: err, at: at, fields: fields }
};

// The position (line, col) moves to over src[a:b].
def fstr_adv(src: str, a: long, b: long, line: long, col: long) -> { line: long, col: long } {
    let ln = line;
    let cl = col;
    let i = a;
    while (i < b) {
        if (byte_at(src, i) == 10) { ln = ln + 1; cl = 1; } else { cl = cl + 1; };
        i = i + 1;
    };
    { line: ln, col: cl }
};

// The tokens of the f-string whose `f` is at (line, col) and whose opening
// quote is src[q], appended to toks; returns where lexing goes on. It is a
// concatenation, each field a call of `#fmt` -- a name no program can bind,
// which types.y (typeof_fmt) checks and native.y (gen_fmt) emits:
//   f"a{x}b{y:>5}"  ->  ( "a" + #fmt(x, "") + "b" + #fmt(y, ">5") )
// A field's expression is tokenized on its own, its tokens moved to where
// it stands; the rest sits at the field's `{`. Without fields it is a plain
// string; a broken one is an `ferr` token, which the parser turns into an
// error where the walk stopped.
def lex_fstring(src: str, q: long, line: long, col: long, toks: [Tok]) -> { end: long, line: long, col: long } {
    let w = fstr_walk(src, q);
    let fs = w.fields;
    if (w.err != "") {
        let ep = fstr_adv(src, q - 1, w.at, line, col);
        toks += mktok("ferr", w.err, ep.line, ep.col);
    } else if (len(fs) == 0) {
        toks += mktok("str", unescape(src[q + 1:w.end - 1], true), line, col);
    } else {
        toks += mktok("punct", "(", line, col);
        let from = q + 1;
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
            if (k > 0) { toks += mktok("op", "+", bl, bc); }
            if (lo - 1 > from) {
                toks += mktok("str", unescape(src[from:lo - 1], true), bl, bc);
                toks += mktok("op", "+", bl, bc);
            }
            toks += mktok("id", "#fmt", bl, bc);
            toks += mktok("punct", "(", bl, bc);
            let sub = tokenize(src[lo:hi]);
            let j = 0;
            while (j + 1 < len(sub)) {
                let tk = sub[j];
                if (tk.line == 1) {
                    toks += mktok(tk.t, tk.v, bl, bc + tk.col);
                } else {
                    toks += mktok(tk.t, tk.v, bl + tk.line - 1, tk.col);
                };
                j = j + 1;
            };
            toks += mktok("punct", ",", bl, bc);
            if (slo >= 0) {
                toks += mktok("str", src[slo:fs[k + 3]], bl, bc);
                from = fs[k + 3] + 1;
            } else {
                toks += mktok("str", "", bl, bc);
                from = hi + 1;
            };
            toks += mktok("punct", ")", bl, bc);
            k = k + 4;
        };
        if (w.end - 1 > from) {
            toks += mktok("op", "+", bl, bc);
            toks += mktok("str", unescape(src[from:w.end - 1], true), bl, bc);
        }
        toks += mktok("punct", ")", bl, bc);
    };
    let e = fstr_adv(src, q - 1, w.end, line, col);
    { end: w.end, line: e.line, col: e.col }
};

def mktok(t: str, v: str, line: long, col: long) -> Tok {
    { t: t, v: v, line: line, col: col }
};

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
def hexvalx(c: str) -> long {
    let o = ord(c);
    if (o >= c'0' && o <= c'9') { o - c'0' }
    else if (o >= c'A' && o <= c'F') { o - c'A' + 10 }
    else if (o >= c'a' && o <= c'f') { o - c'a' + 10 }
    else { -1 }
};

// Try to read an operator of two or more chars at position i (c is the char
// there): the longest one, or "". Maximal munch, like C: `x+++y` is
// `x ++ + y` and `a>>>=b` is `a >>>= b`. There is no `=+` operator;
// `x =+ y` is `x = +y`. Only the shifts are longer than two chars, so only
// `<` and `>` look further ahead. `?.` (option propagation, parser.y
// parse_postfix) is the one operator that shadows another: `a?.b` never
// lexes as the ternary `a ? .b`, and `c ?.5 : 1` -- a conditional whose arm
// starts with a fraction, which no program wants -- is a syntax error, as
// in C.
def multicharop(src: str, i: long, c: str) -> str {
    if (c == "<" || c == ">") {
        let four = src[i:i + 4];
        let three = src[i:i + 3];
        if (four == ">>>=") { four }
        else if (three == ">>>" || three == ">>=" || three == "<<=") { three }
        else { twocharop(src, i) }
    } else {
        twocharop(src, i)
    }
};

// Try to read a two-char operator at position i. Returns the operator or "".
def twocharop(src: str, i: long) -> str {
    let two = src[i:i + 2];
    if (two == "==" || two == "!=" || two == "<=" || two == ">=" ||
        two == "&&" || two == "||" || two == "::" || two == ".." ||
        two == "->" || two == "=>" || two == "++" || two == "--" ||
        two == "?." ||
        two == "+=" || two == "-=" || two == "*=" || two == "/=" ||
        two == "%=" || two == "&=" || two == "|=" || two == "^=" ||
        two == "<<" || two == ">>") { two }
    else { "" }
};

// A one-character operator.
def issingleop(c: byte) -> bool {
    c == c'+' || c == c'-' || c == c'*' || c == c'/' || c == c'%' ||
    c == c'<' || c == c'>' || c == c'=' || c == c'.' || c == c'!' ||
    c == c'&' || c == c'?' || c == c'|' || c == c'^' || c == c'~'
};

// The slash character, in one place: this file's own source contains no bare
// "/" outside this literal and the "/=" test in twocharop, so the comment
// dispatch in tokenize (line comment / block comment / division) is the only
// place a slash in the source being lexed is ever interpreted.
def slash() -> str { "/" };


def isdigitch(c: byte) -> bool {
    // single-char predicate on a 1-char string (native-safe: no ord()).
    if ( c == c'0') { true }
    else if ( c == c'1') { true }
    else if ( c == c'2') { true }
    else if ( c == c'3') { true }
    else if ( c == c'4') { true }
    else if ( c == c'5') { true }
    else if ( c == c'6') { true }
    else if ( c == c'7') { true }
    else if ( c == c'8') { true }
    else { c == c'9' }
};

def tokenize(src: str) -> [Tok] {
    let toks: [Tok] = [];
    let i = 0;
    let n = len(src);
    let line = 1;
    let col = 1;
    while (i < n) {
        let c = src[i];
        if (isspace(c)) {
            if (c == c'\n') { line = line + 1; col = 1; }
            else { col = col + 1; };
            i = i + 1;
        } else if (isdigit(c)) {
            let start = i;
            let startcol = col;
            // 0x../0X.. (hex) and 0b../0B.. (binary) integer literals.
            let radix = 0;
            if (c == c'0') {
                let nxt = src[i + 1:i + 2];
                if (nxt == "x" || nxt == "X") { radix = 16; }
                else if (nxt == "b" || nxt == "B") { radix = 2; };
            };
            // the message of a malformed literal (an ferr token), or ""
            let err = "";
            if (radix > 0) {
                i = i + 2;
                col = col + 2;
                let digits = false;
                let rdone = false;
                while (rdone == false) {
                    if (i < n) {
                        let rc = src[i];
                        if (is_radix_ch(rc, radix)) {
                            if (rc != c'_') { digits = true; };
                            i = i + 1;
                            col = col + 1;
                        } else { rdone = true; };
                    } else { rdone = true; };
                };
                if (!digits) {
                    // A prefix without a digit (`0x`, `0b_`, `0b2`) is no
                    // number: the word characters after it are taken into
                    // the bad literal, reported once, where it starts.
                    while (i < n && isalnum(src[i])) { i = i + 1; col = col + 1; };
                    if (radix == 16) { err = "hex literal '" + src[start:i] + "' has no digits"; }
                    else { err = "binary literal '" + src[start:i] + "' has no digits"; };
                };
            } else {
            // The first digit is already known from the branch condition.
            // After the first digit of each part (whole, fraction,
            // exponent) `_` may separate digits: 1_000_000, 0.000_1.
            i = i + 1;
            col = col + 1;
            let ind = false;
            while (ind == false) {
                if (i < n) {
                    let dc = src[i];
                    if (isdigit(dc) || dc == c'_') { i = i + 1; col = col + 1; }
                    else { ind = true; };
                } else { ind = true; };
            };
            // optional fractional part (but not '..' range).
            if (src[i:i + 1] == "." && src[i + 1:i + 2] != ".") {
                i = i + 1;
                col = col + 1;
                let fs = i;
                let frd = false;
                while (frd == false) {
                    if (i < n) {
                        let fc = src[i];
                        if (isdigit(fc) || (fc == c'_' && i > fs)) { i = i + 1; col = col + 1; }
                        else { frd = true; };
                    } else { frd = true; };
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
                    let exd = false;
                    while (exd == false) {
                        if (i < n) {
                            let xc = src[i];
                            if (isdigit(xc) || xc == c'_') { i = i + 1; col = col + 1; }
                            else { exd = true; };
                        } else { exd = true; };
                    };
                };
            };
            };
            let txt = src[start:i];
            if (err != "") {
                toks += mktok("ferr", err, line, startcol);
            } else {
                if (radix == 0) { txt = strip_seps(txt); };
                toks += mktok("num", txt, line, startcol);
            };
        } else if (isalpha(c)) {
            let start = i;
            let startcol = col;
            // The first character is already known to be a word character.
            i = i + 1;
            col = col + 1;
            let inw = false;
            while (inw == false) {
                if (i < n) {
                    if (isalnum(src[i])) { i = i + 1; col = col + 1; }
                    else { inw = true; };
                } else { inw = true; };
            };
            let word = src[start:i];
            let ty = "id";
            if (word == "let") { ty = "kw"; }
            else if (word == "const") { ty = "kw"; }
            else if (word == "def") { ty = "kw"; }
            else if (word == "if") { ty = "kw"; }
            else if (word == "else") { ty = "kw"; }
            else if (word == "while") { ty = "kw"; }
            else if (word == "for") { ty = "kw"; }
            else if (word == "foreach") { ty = "kw"; }
            else if (word == "in") { ty = "kw"; }
            else if (word == "return") { ty = "kw"; }
            else if (word == "true") { ty = "kw"; }
            else if (word == "false") { ty = "kw"; }
           ;
            if (word == "b") {
                // b"..." / b'...' -- a byte-string literal: the same type
                // as [byte], spelled like a Python bytes literal.
                let bline = line;
                let qch = src[i:i + 1];
                if (qch == "\"") {
                    let bq = lex_quoted(src, i, line, col);
                    i = bq.end;
                    line = bq.line;
                    col = bq.col;
                    toks += mktok("bstr", bq.text, bline, startcol);
                } else if (qch == "'") {
                    let bq2 = lex_quoted(src, i, line, col);
                    i = bq2.end;
                    line = bq2.line;
                    col = bq2.col;
                    toks += mktok("bstr", bq2.text, bline, startcol);
                } else {
                    toks += mktok(ty, word, line, startcol);
                };
            } else if (word == "c" && src[i:i + 1] == "'") {
                // c'a' -- a character literal: one byte, typed `byte`.
                let cline = line;
                let cq = lex_quoted(src, i, line, col);
                i = cq.end;
                line = cq.line;
                col = cq.col;
                toks += mktok("char", cq.text, cline, startcol);
            } else if (word == "f" && src[i:i + 1] == "\"") {
                // f"..." -- an f-string (lex_fstring)
                let fq = lex_fstring(src, i, line, startcol, toks);
                i = fq.end;
                line = fq.line;
                col = fq.col;
            } else {
                toks += mktok(ty, word, line, startcol);
            };
        } else if (c == c'"') {
            // string literal with escapes. NOTE: this arm precedes the slash
            // arms below: every slash inside quotes is consumed here, so the
            // slash arms only ever see real comment openers or operators.
            let startline = line;
            let startcol = col;
            let q = lex_quoted(src, i, line, col);
            i = q.end;
            line = q.line;
            col = q.col;
            toks += mktok("str", q.text, startline, startcol);
        } else if (c == c'/') {
            // Slash: comment opener, block comment, or division operator.
            // (The string arm above consumed every slash inside quotes, so a
            // slash reaching here is real code.) Look ahead one char:
            // slash-slash = line comment, slash-star = block comment,
            // anything else = division operator. No lone-slash error:
            // division is ordinary code, so the operator is emitted.
            if (src[i + 1:i + 2] == slash()) {
                // line comment
                i = i + 2;
                col = col + 2;
                let done = false;
                while (done == false) {
                    if (i < n) {
                        if (src[i:i + 1] != "\n") { i = i + 1; col = col + 1; }
                        else { done = true; };
                    } else { done = true; };
                };
            } else if (src[i + 1:i + 2] == "*") {
                i = i + 2;
                col = col + 2;
                let open = true;
                let closed = false;
                while (open) {
                    if (i + 1 < n) {
                        if (src[i:i + 2] == "*/") {
                            i = i + 2;
                            col = col + 2;
                            open = false;
                            closed = true;
                        } else {
                            let ch = src[i:i + 1];
                            if (ch == "\n") { line = line + 1; col = 1; }
                            else { col = col + 1; };
                            i = i + 1;
                        };
                    } else { open = false; };
                };
                if (!closed) {
                    // ran off the end with the comment still open: fatal,
                    // like an unterminated string (the rest of the file
                    // was silently swallowed)
                    puts("error: unterminated block comment\n");
                    exit(1);
                };
            } else {
                // division operator or `/=` (not a comment opener). The
                // comment dispatch above owns the `/` branch, so `/=` has
                // to be recognized HERE — the generic twocharop dispatch
                // below never sees it.
                let two = twocharop(src, i);
                if (two == "/=") {
                    toks += mktok("op", two, line, col);
                    i = i + 2;
                    col = col + 2;
                } else {
                    toks += mktok("op", slash(), line, col);
                    i = i + 1;
                    col = col + 1;
                };
            };
        } else {
            // operator / punct / unknown-char dispatch.
            let op = multicharop(src, i, src[i:i + 1]);
            if (op != "") {
                toks += mktok("op", op, line, col);
                i = i + len(op);
                col = col + len(op);
            } else if (issingleop(c)) {
                toks += mktok("op", src[i:i + 1], line, col);
                i = i + 1;
                col = col + 1;
            } else if (ispunct(c)) {
                toks += mktok("punct", src[i:i + 1], line, col);
                i = i + 1;
                col = col + 1;
            } else {
                // A character no token starts with: passed on as an
                // operator nothing accepts, so the parser reports it
                // (skipping it compiled `5 @ 3` as `5 3`).
                toks += mktok("op", src[i:i + 1], line, col);
                i = i + 1;
                col = col + 1;
            };
        };
    };
    toks += mktok("eof", "", line, col);
    toks
};

export { tokenize, fstr_walk };
