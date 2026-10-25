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

def is_punct(c: str) -> bool {
    c == "(" || c == ")" || c == "{" || c == "}" || c == "[" || c == "]" ||
    c == "," || c == ";" || c == ":"
};

def mk_tok(t: str, v: str) -> { t: str, v: str } {
    { t: t, v: v }
};

def two_char_op(src: str, i: long) -> str {
    let two = src[i:i + 2];
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
    let toks: [{ t: str, v: str }] = [];
    let i = 0;
    let n = len(src);
    while (i < n) {
        let c = src[i:i + 1];
        if (is_space(c)) {
            i = i + 1;
        } else if (c == "/" && src[i + 1:i + 2] == "/") {
            i = i + 2;
            while (i < n && src[i:i + 1] != "\n") { i = i + 1; };
        } else if (c == "/" && src[i + 1:i + 2] == "*") {
            i = i + 2;
            let open = true;
            while (open && i + 1 < n) {
                if (src[i:i + 2] == "*/") {
                    i = i + 2;
                    open = false;
                    0;
                } else {
                    i = i + 1;
                };
            };
        } else if (is_digit(c)) {
            let start = i;
            while (i < n && is_digit(src[i:i + 1])) { i = i + 1; };
            if (src[i:i + 1] == "." && src[i + 1:i + 2] != ".") {
                i = i + 1;
                while (i < n && is_digit(src[i:i + 1])) { i = i + 1; };
            };
            toks += mk_tok("num", src[start:i]);
            0;
        } else if (is_alpha(c)) {
            let start = i;
            while (i < n && is_alnum(src[i:i + 1])) { i = i + 1; };
            let word = src[start:i];
            let ty = "id";
            if (word == "let" || word == "const" || word == "def" ||
                word == "if" || word == "else" || word == "while" ||
                word == "for" || word == "foreach" || word == "in" ||
                word == "return" || word == "true" || word == "false" ||
                word == "null") {
                ty = "kw";
                0;
            };
            toks += mk_tok(ty, word);
            0;
        } else if (c == "\"") {
            i = i + 1;
            let buf = "";
            let open = true;
            while (open && i < n) {
                let ch = src[i:i + 1];
                if (ch == "\\") {
                    let esc = src[i + 1:i + 2];
                    if (esc == "n") { buf = buf + "\n"; i = i + 2; }
                    else if (esc == "t") { buf = buf + "\t"; i = i + 2; }
                    else if (esc == "r") { buf = buf + "\r"; i = i + 2; }
                    else if (esc == "\\") { buf = buf + "\\"; i = i + 2; }
                    else if (esc == "\"") { buf = buf + "\""; i = i + 2; }
                    else { buf = buf + esc; i = i + 2; };
                } else if (ch == "\"") {
                    i = i + 1;
                    open = false;
                    0;
                } else {
                    buf = buf + ch;
                    i = i + 1;
                };
            };
            toks += mk_tok("str", buf);
            0;
        } else {
            let two = two_char_op(src, i);
            if (two != "") {
                toks += mk_tok("op", two);
                i = i + 2;
            } else if (is_single_op(c)) {
                toks += mk_tok("op", c);
                i = i + 1;
            } else if (is_punct(c)) {
                toks += mk_tok("punct", c);
                i = i + 1;
            } else {
                i = i + 1;
            };
        };
    };
    toks += mk_tok("eof", "");
    toks
};

let src = "let x = \"hi\\n\";";
print("calling tokenize...");
let toks = tokenize(src);
print("done, count = " + tostring(len(toks)));
