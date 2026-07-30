// lexer.y — tokenize a Y source string into a list of token maps.
// Each token is { t: <type>, v: <lexeme/value> }.
// Token types: id, num, str, op, punct, kw, eof.

def is_digit(c: str) -> bool {
    let o = ord(c);
    o >= 48 && o <= 57
};

def is_alpha(c: str) -> bool {
    let o = ord(c);
    (o >= 65 && o <= 90) || (o >= 97 && o <= 122) || o == 95
};

def is_alnum(c: str) -> bool {
    is_digit(c) || is_alpha(c)
};

def is_space(c: str) -> bool {
    c == " " || c == "\t" || c == "\n" || c == "\r"
};

// is c one of the single-char punctuation symbols?
def is_punct(c: str) -> bool {
    c == "(" || c == ")" || c == "{" || c == "}" || c == "[" || c == "]" ||
    c == "," || c == ";" || c == ":"
};

def mk_tok(t: str, v: str) -> { t: str, v: str } {
    { t: t, v: v }
};

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
def hexval(c: str) -> long {
    let o = ord(c);
    if (o >= 48 && o <= 57) { o - 48 }
    else if (o >= 65 && o <= 70) { o - 65 + 10 }
    else if (o >= 97 && o <= 102) { o - 97 + 10 }
    else { -1 }
};

// Try to read a two-char operator at position i. Returns the operator or "".
def two_char_op(src: str, i: long) -> str {
    let two = substr(src, i, 2);
    if (two == "==" || two == "!=" || two == "<=" || two == ">=" ||
        two == "&&" || two == "||" || two == "::" || two == ".." ||
        two == "->") {
        two
    } else {
        ""
    }
};

def is_single_op(c: str) -> bool {
    c == "+" || c == "-" || c == "*" || c == "/" || c == "%" ||
    c == "<" || c == ">" || c == "=" || c == "." || c == "!"
};

def tokenize(src: str) -> [{ t: str, v: str }] {
    let toks = [];
    let i = 0;
    let n = len(src);
    while (i < n) {
        let c = substr(src, i, 1);
        if (is_space(c)) {
            i = i + 1;
        } else if (c == "/" && substr(src, i + 1, 1) == "/") {
            // line comment
            i = i + 2;
            while (i < n && substr(src, i, 1) != "\n") { i = i + 1; };
        } else if (c == "/" && substr(src, i + 1, 1) == "*") {
            // block comment
            i = i + 2;
            let open = true;
            while (open && i + 1 < n) {
                if (substr(src, i, 2) == "*/") {
                    i = i + 2;
                    open = false;
                } else {
                    i = i + 1;
                };
            };
        } else if (is_digit(c)) {
            let start = i;
            while (i < n && is_digit(substr(src, i, 1))) { i = i + 1; };
            // optional fractional part (but not '..' range)
            if (substr(src, i, 1) == "." && substr(src, i + 1, 1) != ".") {
                i = i + 1;
                while (i < n && is_digit(substr(src, i, 1))) { i = i + 1; };
            };
            toks = push(toks, mk_tok("num", substr(src, start, i - start)));
        } else if (is_alpha(c)) {
            let start = i;
            while (i < n && is_alnum(substr(src, i, 1))) { i = i + 1; };
            let word = substr(src, start, i - start);
            let ty = "id";
            if (word == "let" || word == "const" || word == "def" ||
                word == "if" || word == "else" || word == "while" ||
                word == "for" || word == "foreach" || word == "in" ||
                word == "return" || word == "true" || word == "false" ||
                word == "null") {
                ty = "kw";
            };
            toks = push(toks, mk_tok(ty, word));
        } else if (c == "\"") {
            // string literal with escapes.
            // Fast path: scan to the closing quote (respecting escapes), extract
            // the raw content with ONE substr, then process escapes only if any
            // backslash is present. Avoids O(n^2) char-by-char concatenation.
            i = i + 1;
            let start = i;
            let open = true;
            let has_esc = false;
            while (open && i < n) {
                let ch = substr(src, i, 1);
                if (ch == "\\") { has_esc = true; i = i + 2; }
                else if (ch == "\"") { open = false; }
                else { i = i + 1; };
            };
            let raw = substr(src, start, i - start);
            i = i + 1;  // skip closing quote
            let buf = raw;
            if (has_esc) {
                // process escapes into a chunk list + join (O(n))
                let chunks = [];
                let k = 0;
                let rn = len(raw);
                while (k < rn) {
                    let rc = substr(raw, k, 1);
                    if (rc == "\\") {
                        let esc = substr(raw, k + 1, 1);
                        if (esc == "n") { chunks = push(chunks, "\n"); k = k + 2; }
                        else if (esc == "t") { chunks = push(chunks, "\t"); k = k + 2; }
                        else if (esc == "r") { chunks = push(chunks, "\r"); k = k + 2; }
                        else if (esc == "x") {
                            // \xHH — two hex digits
                            let h1 = hexval(substr(raw, k + 2, 1));
                            let h2 = hexval(substr(raw, k + 3, 1));
                            if (h1 >= 0 && h2 >= 0) {
                                chunks = push(chunks, chr(h1 * 16 + h2));
                                k = k + 4;
                            } else {
                                chunks = push(chunks, esc);
                                k = k + 2;
                            };
                        }
                        else { chunks = push(chunks, esc); k = k + 2; };
                    } else {
                        chunks = push(chunks, rc);
                        k = k + 1;
                    };
                };
                buf = join(chunks, "");
            };
            toks = push(toks, mk_tok("str", buf));
        } else {
            let two = two_char_op(src, i);
            if (two != "") {
                toks = push(toks, mk_tok("op", two));
                i = i + 2;
            } else if (is_single_op(c)) {
                toks = push(toks, mk_tok("op", c));
                i = i + 1;
            } else if (is_punct(c)) {
                toks = push(toks, mk_tok("punct", c));
                i = i + 1;
            } else {
                // unknown char — skip
                i = i + 1;
            };
        };
    };
    toks = push(toks, mk_tok("eof", ""));
    toks
};

export { tokenize };
