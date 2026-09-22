// lexer.y — tokenize a Y source string into a list of token maps.
// Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
// Token types: id, num, str, op, punct, kw, eof.

// NOTE: short underscore-free names (isdigit/isalpha/...) — see below.
def isdigit(c: str) -> bool {
    // NOTE: nested ifs, not `&&` (see isalnum note below): the C VM
    // evaluates both sides eagerly AND the native checker rejects `&&`
    // whose operand shapes disagree (comparison-bool vs map-field access
    // both poison through `&&`; plain comparison pairs are fine, but the
    // uniform nested-if style keeps both toolchains quiet everywhere).
    let o = ord(c);
    if (o >= 48) {
        if (o <= 57) { true } else { false }
    } else { false }
};

def isalpha(c: str) -> bool {
    // word chars: letters AND underscore (chr(95)) AND digits (Y words like
    // "t0"/"r64" contain digits; the C backend's take_alpha accepts them too
    // via is_alpha... precisely: parser.c is_alpha includes is_digit, so
    // "t0" lexes as one id there as well — parity).
    let o = ord(c);
    if (o >= 65) {
        if (o <= 90) { true }
        else if (o >= 97) {
            if (o <= 122) { true } else { false }
        } else if (o == 95) { true }
        else if (o >= 48) {
            if (o <= 57) { true } else { false }
        } else { false }
    } else if (o == 95) { true }
    else if (o >= 48) {
        if (o <= 57) { true } else { false }
    } else { false }
};

def isalnum(c: str) -> bool {
    // NOTE: no `||` of bools here — the C VM evaluates both sides eagerly
    // AND the native checker types `||` operands strictly; nested ifs keep
    // both toolchains quiet.
    if (isdigit(c)) { true } else { isalpha(c) }
};

def isspace(c: str) -> bool {
    if (c == " ") { true }
    else if (c == "\t") { true }
    else if (c == "\n") { true }
    else { c == "\r" }
};

// NOTE: isdigit/isalpha/isalnum-style names MUST avoid underscores AND the
// is_* prefix: Y's own lexer (this file) treats "_" as a word character for
// isalpha(), but the C toolchain's parser.c parse_identifier splits "isdigit"
// into `is`, `_`, `digit`... precisely: the Y lexer emits "isdigit" as ONE
// id token (isalnum includes "_"), while parser.c's take_alpha stops at "_"
// (its isalpha lacks "_"), so the C backend sees three tokens and the rename
// pass shreds every def whose name contains an underscore. All predicate
// names in ycc/*.y therefore use the flat isalpha/isdigit/isalnum style.

// is c one of the single-char punctuation symbols?
// NOTE: nested ifs, not `||` chains — the native checker rejects `||`
// whose operands disagree, and `==` on strings yields bool while a bare
// `c` or chained comparison can poison a branch (see isalnum note).
def ispunct(c: str) -> bool {
    if (c == "(") { true }
    else if (c == ")") { true }
    else if (c == "{") { true }
    else if (c == "}") { true }
    else if (c == "[") { true }
    else if (c == "]") { true }
    else if (c == ",") { true }
    else if (c == ";") { true }
    else { c == ":" }
};

def mktok(t: str, v: str, line: long, col: long) -> { t: str, v: str, line: long, col: long } {
    { t: t, v: v, line: line, col: col }
};

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
// NOTE: nested ifs, not `&&` chains (see isdigit note).
def hexvalx(c: str) -> long {
    let o = ord(c);
    if (o >= 48) {
        if (o <= 57) { o - 48 }
        else if (o >= 65) {
            if (o <= 70) { o - 65 + 10 }
            else if (o >= 97) {
                if (o <= 102) { o - 97 + 10 } else { -1 }
            } else { -1 }
        } else { -1 }
    } else { -1 }
};

// Try to read a two-char operator at position i. Returns the operator or "".
// NOTE: nested ifs, not `||` chains (see ispunct note).
def twocharop(src: str, i: long) -> str {
    let two = substr(src, i, 2);
    if (two == "==") { two }
    else if (two == "!=") { two }
    else if (two == "<=") { two }
    else if (two == ">=") { two }
    else if (two == "&&") { two }
    else if (two == "||") { two }
    else if (two == "::") { two }
    else if (two == "..") { two }
    else if (two == "->") { two }
    else { "" }
};

def issingleop(c: str) -> bool {
    if (c == "+") { true }
    else if (c == "-") { true }
    else if (c == "*") { true }
    else if (c == slash()) { true }
    else if (c == "%") { true }
    else if (c == "<") { true }
    else if (c == ">") { true }
    else if (c == "=") { true }
    else if (c == ".") { true }
    else if (c == "!") { true }
    else if (c == "&") { true }
    else { c == "?" }
};

// The slash character, built without a literal: Y string literals cannot
// spell it... precisely: they CAN (c == slash-char works in comparisons),
// but a bare slash char inside a comment or adjacent to code confuses the
// dispatch reasoning above, so every slash reference goes through this one
// helper (chr(47)). Single source of truth, zero literal slashes outside
// strings in this file.
def slash() -> str { chr(47) };

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
            let ind = false;
            while (ind == false) {
                if (i < n) {
                    if (isdigit(substr(src, i, 1))) { i = i + 1; col = col + 1; 0; }
                    else { ind = true; 0; };
                    0
                } else { ind = true; 0 };
            };
            // optional fractional part (but not '..' range).
            // NOTE: no `&&` (see line-comment note): check the dot, then the
            // lookahead, in nested form.
            if (substr(src, i, 1) == ".") {
                if (substr(src, i + 1, 1) != ".") {
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
                } else { 0 };
                0
            } else { 0 };
            toks = push(toks, mktok("num", substr(src, start, i - start), line, startcol));
            0
        } else if (isalpha(c)) {
            let start = i;
            let startcol = col;
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
            else if (word == "null") { ty = "kw"; 0; }
            else { 0 };
            toks = push(toks, mktok(ty, word, line, startcol));
            0
        } else if (c == "\"") {
            // string literal with escapes. NOTE: this arm precedes the slash
            // arms below: every slash inside quotes is consumed here, so the
            // slash arms only ever see real comment openers or operators.
            // Fast path: scan to the closing quote (respecting escapes), extract
            // the raw content with ONE substr, then process escapes only if any
            // backslash is present. Avoids O(n^2) char-by-char concatenation.
            let startline = line;
            let startcol = col;
            i = i + 1;
            col = col + 1;
            let start = i;
            let open = true;
            let hasesc = false;
            while (open) {
                if (i < n) {
                    let ch = substr(src, i, 1);
                    if (ch == "\\") { hasesc = true; i = i + 2; col = col + 2; 0; }
                    else if (ch == "\"") { open = false; 0; }
                    else {
                        if (ch == "\n") { line = line + 1; col = 1; 0; }
                        else { col = col + 1; 0; };
                        i = i + 1;
                        0
                    };
                    0
                } else { open = false; 0 };
            };
            if (open) {
                puts("error: unterminated string literal\n");
                0
            } else { 0 };
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
                        if (esc == "n") { chunks = push(chunks, "\n"); k = k + 2; 0; }
                        else if (esc == "t") { chunks = push(chunks, "\t"); k = k + 2; 0; }
                        else if (esc == "r") { chunks = push(chunks, "\r"); k = k + 2; 0; }
                        else if (esc == "x") {
                            // \xHH — two hex digits
                            let h1 = hexvalx(substr(raw, k + 2, 1));
                            let h2 = hexvalx(substr(raw, k + 3, 1));
                            if (h1 >= 0 && h2 >= 0) {
                                chunks = push(chunks, chr(h1 * 16 + h2));
                                k = k + 4;
                                0
                            } else {
                                chunks = push(chunks, esc);
                                k = k + 2;
                                0
                            };
                            0
                        }
                        else { chunks = push(chunks, esc); k = k + 2; 0; };
                        0
                    } else {
                        chunks = push(chunks, rc);
                        k = k + 1;
                        0
                    };
                };
                buf = join(chunks, "");
                0
            } else { 0 };
            toks = push(toks, mktok("str", buf, startline, startcol));
            0
        } else if (c == slash()) {
            // Slash: comment opener, block comment, or division operator.
            // (The string arm above consumed every slash inside quotes, so a
            // slash reaching here is real code.) Look ahead one char:
            // slash-slash = line comment, slash-star = block comment,
            // anything else = division operator. No lone-slash error: the C
            // backend lexes division identically (parser.c skip_spaces skips
            // comments, parse_operator matches division), so parity demands
            // we emit the operator too.
            // NOTE: no `&&` guard (see below) — nested-if form.
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
                } else { 0 };
                0
            } else {
                // division operator (not a comment opener)
                toks = push(toks, mktok("op", slash(), line, col));
                i = i + 1;
                col = col + 1;
                0
            };
        } else {
            // operator / punct / unknown-char dispatch. NOTE: bound once —
            // twocharop(src, i) inline inside a call misparses on the C
            // backend (it reads `f(g(x), ...)` args with dot/index shapes
            // as field access; see native.y strip_ns note).
            let two = twocharop(src, i);
            if (two != "") {
                toks = push(toks, mktok("op", two, line, col));
                i = i + 2;
                col = col + 2;
                0
            } else if (issingleop(c)) {
                toks = push(toks, mktok("op", c, line, col));
                i = i + 1;
                col = col + 1;
                0
            } else if (ispunct(c)) {
                toks = push(toks, mktok("punct", c, line, col));
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
    toks = push(toks, mktok("eof", "", line, col));
    toks
};

export { tokenize };
