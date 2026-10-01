// lexer.y — tokenize a Y source string into a list of token maps.
// Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
// Token types: id, num, str, bstr, char, op, punct, kw, eof, and ferr -- a
// broken f-string, v its error message (lex_fstring).

// NOTE: short underscore-free names (isdigit/isalpha/...) — see below.
def isdigit(c: str) -> bool {
    c >= "0" && c <= "9"
};

def isupper(c: str) -> bool {
    c >= "A" && c <= "Z"
};

def islower(c: str) -> bool {
    c >= "a" && c <= "z"
};

def isalpha(c: str) -> bool {
    // word chars: letters AND underscore (chr(95)) AND digits — Y words
    // like "t0"/"r64" contain digits, which is why the scan after the first
    // character is isalnum (letters + digits + "_"). The C twin's isalpha
    // /isalnum are the same two tests (src/c/lexer.c), so both lexers split
    // identifiers identically.
    islower(c) || isupper(c) || c == "_" || isdigit(c)
};

def isalnum(c: str) -> bool {
    isdigit(c) || isalpha(c)
};

// Digit of a radix literal (0x.. / 0b..), including `_` separators.
def is_radix_ch(c: str, radix: long) -> bool {
    if (c == "_") { true }
    else if (radix == 2) { c == "0" || c == "1" }
    else { isdigit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") }
};

def isspace(c: str) -> bool {
    c == " " || c == "\t" || c == "\n" || c == "\r"
};

// NOTE: these predicates keep the flat C spellings isdigit/isupper/islower/
// isalpha/isalnum/isspace/ispunct because <ctype.h> reserves all seven as
// builtin names: the C twin has to rename them (src/c/lexer.h maps each to a
// y_lex_* symbol), and both copies must agree on the Y spelling at the call
// sites. The old companion rule — "avoid underscores, the other lexer stops
// at them" — no longer holds: isalpha above takes "_", and so does the C
// twin's, so a name like is_radix_ch lexes as one identifier in both.

// is c one of the single-char punctuation symbols?
def ispunct(c: str) -> bool {
    c == "(" || c == ")" || c == "{" || c == "}" || c == "[" ||
    c == "]" || c == "," || c == ";" || c == ":"
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
            if (ch == "\\") { hasesc = true; i = i + 2; col = col + 2; 0; }
            else if (ch == q) { open = false; closed = true; 0; }
            else {
                if (ch == "\n") { line = line + 1; col = 1; 0; }
                else { col = col + 1; 0; };
                i = i + 1;
                0
            };
            0
        } else { open = false; 0 };
    };
    if (closed) {
        0
    } else {
        // ran off the end with the quote still open
        puts("error: unterminated string literal\n");
        exit(1);
        0
    };
    let raw = src[start:i];
    i = i + 1;  // skip closing quote
    col = col + 1;
    let buf = raw;
    if (hasesc) {
        buf = unescape(raw, false);
        0
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
            if (esc == "n") { chunks += "\n"; k = k + 2; 0; }
            else if (esc == "t") { chunks += "\t"; k = k + 2; 0; }
            else if (esc == "r") { chunks += "\r"; k = k + 2; 0; }
            else if (esc == "x") {
                // \xHH -- two hex digits
                let h1 = hexvalx(raw[k + 2:k + 3]);
                let h2 = hexvalx(raw[k + 3:k + 4]);
                if (h1 >= 0 && h2 >= 0) {
                    chunks += chr(h1 * 16 + h2);
                    k = k + 4;
                    0
                } else {
                    chunks += esc;
                    k = k + 2;
                    0
                };
                0
            }
            else { chunks += esc; k = k + 2; 0; };
            0
        } else if (braces && (rc == "{" || rc == "}")) {
            chunks += rc;
            k = k + 2;
            0
        } else {
            chunks += rc;
            k = k + 1;
            0
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
    (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95
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
        if (c == 92) { i = i + 2; 0; }
        else if (c == qc) { end = i + 1; open = false; 0; }
        else { i = i + 1; 0; };
        0
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
        if (c == 34 || c == 39) {
            if (c == 34 && i > lo && byte_at(src, i - 1) == 102 && (i - 1 == lo || !wordbyte(byte_at(src, i - 2)))) {
                // a nested f"..."
                i = fstr_walk(src, i).end;
                0
            } else {
                i = lit_end(src, i);
                0
            };
            0
        } else if (c == 40 || c == 91 || c == 123) {
            depth = depth + 1;
            i = i + 1;
            0
        } else if (depth > 0) {
            if (c == 41 || c == 93 || c == 125) { depth = depth - 1; 0; } else { 0; };
            i = i + 1;
            0
        } else if (c == 63) {
            tern = tern + 1;
            i = i + 1;
            0
        } else if (c == 58 && tern > 0) {
            tern = tern - 1;
            i = i + 1;
            0
        } else if (c == 125 || c == 58 || c == 44 || c == 59 || c == 41 || c == 93) {
            stop = i;
            go = false;
            0
        } else {
            i = i + 1;
            0
        };
        0
    };
    stop
};

// Whether src[lo:hi] is all blanks.
def fstr_blank(src: str, lo: long, hi: long) -> bool {
    let i = lo;
    let blank = true;
    while (blank && i < hi) {
        let c = byte_at(src, i);
        blank = c == 32 || c == 9 || c == 10 || c == 13;
        i = i + 1;
        0
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
            0
        } else {
            let c = byte_at(src, i);
            if (c == 92) {
                i = i + 2;
                0
            } else if (c == 34) {
                i = i + 1;
                open = false;
                0
            } else if ((c == 123 || c == 125) && i + 1 < n && byte_at(src, i + 1) == c) {
                i = i + 2;
                0
            } else if (c == 125) {
                err = "single '}' in an f-string (a literal brace is '}}')";
                at = i;
                open = false;
                0
            } else if (c == 123) {
                let lo = i + 1;
                let hi = fstr_expr_end(src, lo);
                let hc = 0;
                if (hi < n) { hc = byte_at(src, hi); 0; } else { 0; };
                if (hc != 125 && hc != 58) {
                    if (hi >= n) {
                        err = "unterminated f-string field";
                        at = i;
                        0
                    } else {
                        err = "an f-string field is one expression, got '" + src[hi:hi + 1] + "'";
                        at = hi;
                        0
                    };
                    open = false;
                    0
                } else if (fstr_blank(src, lo, hi)) {
                    err = "empty f-string field";
                    at = i;
                    open = false;
                    0
                } else if (hc == 125) {
                    fields += lo;
                    fields += hi;
                    fields += 0 - 1;
                    fields += 0 - 1;
                    i = hi + 1;
                    0
                } else {
                    // the spec: up to the closing brace
                    let e = hi + 1;
                    while (e < n && byte_at(src, e) != 125 && byte_at(src, e) != 123 && byte_at(src, e) != 34) {
                        e = e + 1;
                        0
                    };
                    if (e < n && byte_at(src, e) == 125) {
                        fields += lo;
                        fields += hi;
                        fields += hi + 1;
                        fields += e;
                        i = e + 1;
                        0
                    } else {
                        if (e < n && byte_at(src, e) == 123) {
                            err = "a format spec cannot hold '{'";
                            at = e;
                            0
                        } else {
                            err = "unterminated f-string field";
                            at = i;
                            0
                        };
                        open = false;
                        0
                    };
                    0
                };
                0
            } else {
                i = i + 1;
                0
            };
            0
        };
        0
    };
    let end = i;
    if (err != "") { end = lit_end(src, q); 0; } else { 0; };
    { end: end, err: err, at: at, fields: fields }
};

// The position (line, col) moves to over src[a:b].
def fstr_adv(src: str, a: long, b: long, line: long, col: long) -> { line: long, col: long } {
    let ln = line;
    let cl = col;
    let i = a;
    while (i < b) {
        if (byte_at(src, i) == 10) { ln = ln + 1; cl = 1; 0; } else { cl = cl + 1; 0; };
        i = i + 1;
        0
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
def lex_fstring(src: str, q: long, line: long, col: long, toks: [{ t: str, v: str, line: long, col: long }]) -> { end: long, line: long, col: long } {
    let w = fstr_walk(src, q);
    let fs = w.fields;
    if (w.err != "") {
        let ep = fstr_adv(src, q - 1, w.at, line, col);
        toks += mktok("ferr", w.err, ep.line, ep.col);
        0
    } else if (len(fs) == 0) {
        toks += mktok("str", unescape(src[q + 1:w.end - 1], true), line, col);
        0
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
            if (k > 0) { toks += mktok("op", "+", bl, bc); 0; } else { 0; };
            if (lo - 1 > from) {
                toks += mktok("str", unescape(src[from:lo - 1], true), bl, bc);
                toks += mktok("op", "+", bl, bc);
                0
            } else { 0; };
            toks += mktok("id", "#fmt", bl, bc);
            toks += mktok("punct", "(", bl, bc);
            let sub = tokenize(src[lo:hi]);
            let j = 0;
            while (j + 1 < len(sub)) {
                let tk = sub[j];
                if (tk.line == 1) {
                    toks += mktok(tk.t, tk.v, bl, bc + tk.col);
                    0
                } else {
                    toks += mktok(tk.t, tk.v, bl + tk.line - 1, tk.col);
                    0
                };
                j = j + 1;
                0
            };
            toks += mktok("punct", ",", bl, bc);
            if (slo >= 0) {
                toks += mktok("str", src[slo:fs[k + 3]], bl, bc);
                from = fs[k + 3] + 1;
                0
            } else {
                toks += mktok("str", "", bl, bc);
                from = hi + 1;
                0
            };
            toks += mktok("punct", ")", bl, bc);
            k = k + 4;
            0
        };
        if (w.end - 1 > from) {
            toks += mktok("op", "+", bl, bc);
            toks += mktok("str", unescape(src[from:w.end - 1], true), bl, bc);
            0
        } else { 0; };
        toks += mktok("punct", ")", bl, bc);
        0
    };
    let e = fstr_adv(src, q - 1, w.end, line, col);
    { end: w.end, line: e.line, col: e.col }
};

def mktok(t: str, v: str, line: long, col: long) -> { t: str, v: str, line: long, col: long } {
    { t: t, v: v, line: line, col: col }
};

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
def hexvalx(c: str) -> long {
    let o = ord(c);
    if (o >= 48 && o <= 57) { o - 48 }
    else if (o >= 65 && o <= 70) { o - 65 + 10 }
    else if (o >= 97 && o <= 102) { o - 97 + 10 }
    else { -1 }
};

// Try to read a two-char operator at position i. Returns the operator or "".
// Maximal munch, like C: `x+++y` is `x ++ + y`. There is no `=+` operator;
// `x =+ y` is `x = +y`.
def twocharop(src: str, i: long) -> str {
    let two = src[i:i + 2];
    if (two == "==" || two == "!=" || two == "<=" || two == ">=" ||
        two == "&&" || two == "||" || two == "::" || two == ".." ||
        two == "->" || two == "=>" || two == "++" || two == "--" ||
        two == "+=" || two == "-=" || two == "*=" || two == "/=" ||
        two == "%=") { two }
    else { "" }
};

def issingleop(c: str) -> bool {
    c == "+" || c == "-" || c == "*" || c == slash() || c == "%" ||
    c == "<" || c == ">" || c == "=" || c == "." || c == "!" ||
    c == "&" || c == "?" || c == "|"
};

// The slash character, in one place: this file's own source contains no bare
// "/" outside this literal and the "/=" test in twocharop, so the comment
// dispatch in tokenize (line comment / block comment / division) is the only
// place a slash in the source being lexed is ever interpreted.
def slash() -> str { "/" };

def isdigitch(c: str) -> bool {
    // single-char predicate on a 1-char string (native-safe: no ord()).
    if (c == "0") { true }
    else if (c == "1") { true }
    else if (c == "2") { true }
    else if (c == "3") { true }
    else if (c == "4") { true }
    else if (c == "5") { true }
    else if (c == "6") { true }
    else if (c == "7") { true }
    else if (c == "8") { true }
    else { c == "9" }
};

def tokenize(src: str) -> [{ t: str, v: str, line: long, col: long }] {
    let toks: [{ t: str, v: str, line: long, col: long }] = [];
    let i = 0;
    let n = len(src);
    let line = 1;
    let col = 1;
    while (i < n) {
        let c = src[i:i + 1];
        if (isspace(c)) {
            if (c == "\n") { line = line + 1; col = 1; 0; }
            else { col = col + 1; 0; };
            i = i + 1;
            0
        } else if (isdigit(c)) {
            let start = i;
            let startcol = col;
            // 0x../0X.. (hex) and 0b../0B.. (binary) integer literals.
            let radix = 0;
            if (c == "0") {
                let nxt = src[i + 1:i + 2];
                if (nxt == "x" || nxt == "X") { radix = 16; }
                else if (nxt == "b" || nxt == "B") { radix = 2; };
            };
            if (radix > 0) {
                i = i + 2;
                col = col + 2;
                let rdone = false;
                while (rdone == false) {
                    if (i < n) {
                        if (is_radix_ch(src[i:i + 1], radix)) { i = i + 1; col = col + 1; 0; }
                        else { rdone = true; 0; };
                        0
                    } else { rdone = true; 0 };
                };
                0
            } else {
            // The first digit is already known from the branch condition.
            i = i + 1;
            col = col + 1;
            let ind = false;
            while (ind == false) {
                if (i < n) {
                    if (isdigit(src[i:i + 1])) { i = i + 1; col = col + 1; 0; }
                    else { ind = true; 0; };
                    0
                } else { ind = true; 0 };
            };
            // optional fractional part (but not '..' range).
            if (src[i:i + 1] == "." && src[i + 1:i + 2] != ".") {
                i = i + 1;
                col = col + 1;
                let frd = false;
                while (frd == false) {
                    if (i < n) {
                        if (isdigit(src[i:i + 1])) { i = i + 1; col = col + 1; 0; }
                        else { frd = true; 0; };
                        0
                    } else { frd = true; 0 };
                };
                0
            };
            // optional exponent: e / E, an optional sign, then digits. Only
            // consumed when at least one digit follows, so `1e` stays a
            // number followed by an identifier rather than a bad literal.
            let ec = src[i:i + 1];
            if (ec == "e" || ec == "E") {
                let esign = 0;
                let sc = src[i + 1:i + 2];
                if (sc == "+" || sc == "-") { esign = 1; };
                if (isdigit(src[i + 1 + esign:i + 2 + esign])) {
                    i = i + 1 + esign;
                    col = col + 1 + esign;
                    let exd = false;
                    while (exd == false) {
                        if (i < n) {
                            if (isdigit(src[i:i + 1])) { i = i + 1; col = col + 1; 0; }
                            else { exd = true; 0; };
                            0
                        } else { exd = true; 0 };
                    };
                };
            };
            };
            toks += mktok("num", src[start:i], line, startcol);
            0
        } else if (isalpha(c)) {
            let start = i;
            let startcol = col;
            // The first character is already known to be a word character.
            i = i + 1;
            col = col + 1;
            let inw = false;
            while (inw == false) {
                if (i < n) {
                    if (isalnum(src[i:i + 1])) { i = i + 1; col = col + 1; 0; }
                    else { inw = true; 0; };
                    0
                } else { inw = true; 0 };
            };
            let word = src[start:i];
            let ty = "id";
            if (word == "let") { ty = "kw"; 0; }
            else if (word == "const") { ty = "kw"; 0; }
            else if (word == "def") { ty = "kw"; 0; }
            else if (word == "if") { ty = "kw"; 0; }
            else if (word == "else") { ty = "kw"; 0; }
            else if (word == "while") { ty = "kw"; 0; }
            else if (word == "for") { ty = "kw"; 0; }
            else if (word == "foreach") { ty = "kw"; 0; }
            else if (word == "in") { ty = "kw"; 0; }
            else if (word == "return") { ty = "kw"; 0; }
            else if (word == "true") { ty = "kw"; 0; }
            else if (word == "false") { ty = "kw"; 0; }
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
                    0
                } else if (qch == "'") {
                    let bq2 = lex_quoted(src, i, line, col);
                    i = bq2.end;
                    line = bq2.line;
                    col = bq2.col;
                    toks += mktok("bstr", bq2.text, bline, startcol);
                    0
                } else {
                    toks += mktok(ty, word, line, startcol);
                    0
                };
                0
            } else if (word == "c" && src[i:i + 1] == "'") {
                // c'a' -- a character literal: one byte, typed `byte`.
                let cline = line;
                let cq = lex_quoted(src, i, line, col);
                i = cq.end;
                line = cq.line;
                col = cq.col;
                toks += mktok("char", cq.text, cline, startcol);
                0
            } else if (word == "f" && src[i:i + 1] == "\"") {
                // f"..." -- an f-string (lex_fstring)
                let fq = lex_fstring(src, i, line, startcol, toks);
                i = fq.end;
                line = fq.line;
                col = fq.col;
                0
            } else {
                toks += mktok(ty, word, line, startcol);
                0
            };
            0
        } else if (c == "\"") {
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
            0
        } else if (c == slash()) {
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
                        if (src[i:i + 1] != "\n") { i = i + 1; col = col + 1; 0; }
                        else { done = true; 0; };
                        0
                    } else { done = true; 0 };
                };
                0
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
                            0
                        } else {
                            let ch = src[i:i + 1];
                            if (ch == "\n") { line = line + 1; col = 1; 0; }
                            else { col = col + 1; 0; };
                            i = i + 1;
                            0
                        };
                        0
                    } else { open = false; 0 };
                };
                if (!closed) {
                    // ran off the end with the comment still open: fatal,
                    // like an unterminated string (the rest of the file
                    // was silently swallowed)
                    puts("error: unterminated block comment\n");
                    exit(1);
                    0
                };
                0
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
                    0
                } else {
                    toks += mktok("op", slash(), line, col);
                    i = i + 1;
                    col = col + 1;
                    0
                };
                0
            };
        } else {
            // operator / punct / unknown-char dispatch.
            let two = twocharop(src, i);
            if (two != "") {
                toks += mktok("op", two, line, col);
                i = i + 2;
                col = col + 2;
                0
            } else if (issingleop(c)) {
                toks += mktok("op", c, line, col);
                i = i + 1;
                col = col + 1;
                0
            } else if (ispunct(c)) {
                toks += mktok("punct", c, line, col);
                i = i + 1;
                col = col + 1;
                0
            } else {
                // A character no token starts with: passed on as an
                // operator nothing accepts, so the parser reports it
                // (skipping it compiled `5 @ 3` as `5 3`).
                toks += mktok("op", c, line, col);
                i = i + 1;
                col = col + 1;
                0
            };
        };
    };
    toks += mktok("eof", "", line, col);
    toks
};

export { tokenize, fstr_walk };
