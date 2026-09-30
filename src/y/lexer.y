// lexer.y — tokenize a Y source string into a list of token maps.
// Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
// Token types: id, num, str, op, punct, kw, eof.

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
    let q = substr(src, i, 1);
    let n = len(src);
    i = i + 1;
    col = col + 1;
    let start = i;
    let open = true;
    let closed = false;
    let hasesc = false;
    while (open) {
        if (i < n) {
            let ch = substr(src, i, 1);
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
    let raw = substr(src, start, i - start);
    i = i + 1;  // skip closing quote
    col = col + 1;
    let buf = raw;
    if (hasesc) {
        // process escapes into a chunk list + join (O(n))
        let chunks: [str] = [];
        let k = 0;
        let rn = len(raw);
        while (k < rn) {
            let rc = substr(raw, k, 1);
            if (rc == "\\") {
                let esc = substr(raw, k + 1, 1);
                if (esc == "n") { chunks += "\n"; k = k + 2; 0; }
                else if (esc == "t") { chunks += "\t"; k = k + 2; 0; }
                else if (esc == "r") { chunks += "\r"; k = k + 2; 0; }
                else if (esc == "x") {
                    // \xHH -- two hex digits
                    let h1 = hexvalx(substr(raw, k + 2, 1));
                    let h2 = hexvalx(substr(raw, k + 3, 1));
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
            } else {
                chunks += rc;
                k = k + 1;
                0
            };
        };
        buf = join(chunks, "");
        0
    };
    { text: buf, end: i, line: line, col: col }
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
    let two = substr(src, i, 2);
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
        let c = substr(src, i, 1);
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
                let nxt = substr(src, i + 1, 1);
                if (nxt == "x" || nxt == "X") { radix = 16; }
                else if (nxt == "b" || nxt == "B") { radix = 2; };
            };
            if (radix > 0) {
                i = i + 2;
                col = col + 2;
                let rdone = false;
                while (rdone == false) {
                    if (i < n) {
                        if (is_radix_ch(substr(src, i, 1), radix)) { i = i + 1; col = col + 1; 0; }
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
                    if (isdigit(substr(src, i, 1))) { i = i + 1; col = col + 1; 0; }
                    else { ind = true; 0; };
                    0
                } else { ind = true; 0 };
            };
            // optional fractional part (but not '..' range).
            if (substr(src, i, 1) == "." && substr(src, i + 1, 1) != ".") {
                i = i + 1;
                col = col + 1;
                let frd = false;
                while (frd == false) {
                    if (i < n) {
                        if (isdigit(substr(src, i, 1))) { i = i + 1; col = col + 1; 0; }
                        else { frd = true; 0; };
                        0
                    } else { frd = true; 0 };
                };
                0
            };
            // optional exponent: e / E, an optional sign, then digits. Only
            // consumed when at least one digit follows, so `1e` stays a
            // number followed by an identifier rather than a bad literal.
            let ec = substr(src, i, 1);
            if (ec == "e" || ec == "E") {
                let esign = 0;
                let sc = substr(src, i + 1, 1);
                if (sc == "+" || sc == "-") { esign = 1; };
                if (isdigit(substr(src, i + 1 + esign, 1))) {
                    i = i + 1 + esign;
                    col = col + 1 + esign;
                    let exd = false;
                    while (exd == false) {
                        if (i < n) {
                            if (isdigit(substr(src, i, 1))) { i = i + 1; col = col + 1; 0; }
                            else { exd = true; 0; };
                            0
                        } else { exd = true; 0 };
                    };
                };
            };
            };
            toks += mktok("num", substr(src, start, i - start), line, startcol);
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
                    if (isalnum(substr(src, i, 1))) { i = i + 1; col = col + 1; 0; }
                    else { inw = true; 0; };
                    0
                } else { inw = true; 0 };
            };
            let word = substr(src, start, i - start);
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
                let qch = substr(src, i, 1);
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
            } else if (word == "c" && substr(src, i, 1) == "'") {
                // c'a' -- a character literal: one byte, typed `byte`.
                let cline = line;
                let cq = lex_quoted(src, i, line, col);
                i = cq.end;
                line = cq.line;
                col = cq.col;
                toks += mktok("char", cq.text, cline, startcol);
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
            if (substr(src, i + 1, 1) == slash()) {
                // line comment
                i = i + 2;
                col = col + 2;
                let done = false;
                while (done == false) {
                    if (i < n) {
                        if (substr(src, i, 1) != "\n") { i = i + 1; col = col + 1; 0; }
                        else { done = true; 0; };
                        0
                    } else { done = true; 0 };
                };
                0
            } else if (substr(src, i + 1, 1) == "*") {
                i = i + 2;
                col = col + 2;
                let open = true;
                while (open) {
                    if (i + 1 < n) {
                        if (substr(src, i, 2) == "*/") {
                            i = i + 2;
                            col = col + 2;
                            open = false;
                            0
                        } else {
                            let ch = substr(src, i, 1);
                            if (ch == "\n") { line = line + 1; col = 1; 0; }
                            else { col = col + 1; 0; };
                            i = i + 1;
                            0
                        };
                        0
                    } else { open = false; 0 };
                };
                if (open) {
                    puts("error: unterminated block comment\n");
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
                // unknown char — skip
                i = i + 1;
                col = col + 1;
                0
            };
        };
    };
    toks += mktok("eof", "", line, col);
    toks
};

export { tokenize };
