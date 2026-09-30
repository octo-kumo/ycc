/* lexer.c — tokenize a Y source string into a list of token maps.
 * 1:1 C copy of src/y/lexer.y (see PORTING.md).
 * Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
 * Token types: id, num, str, op, punct, kw, eof.
 *
 * NOTE: short underscore-free names (isdigit/isalpha/...) — see below. */

#include "lexer.h"

// NOTE: nested ifs, not `&&` (see isalnum note below): the C VM
// evaluates both sides eagerly AND the native checker rejects `&&`
// whose operand shapes disagree (comparison-bool vs map-field access
// both poison through `&&`; plain comparison pairs are fine, but the
// uniform nested-if style keeps both toolchains quiet everywhere).
int isdigit(Yv *c) {
    // Range compares on the 1-char string, not ord(c): ord goes through
    // bytes(), which allocates a copy of the string per character, and the
    // lexer classifies every character of the source. Comparisons land in
    // y_str_eq/y_str_cmp — byte primitives, no allocation.
    if (ys_cmp(c, ys("0")) >= 0) {
        if (ys_cmp(c, ys("9")) <= 0) { return 1; } else { return 0; }
    } else { return 0; }
}

int isupper(Yv *c) {
    if (ys_cmp(c, ys("A")) >= 0) {
        if (ys_cmp(c, ys("Z")) <= 0) { return 1; } else { return 0; }
    } else { return 0; }
}

int islower(Yv *c) {
    if (ys_cmp(c, ys("a")) >= 0) {
        if (ys_cmp(c, ys("z")) <= 0) { return 1; } else { return 0; }
    } else { return 0; }
}

int isalpha(Yv *c) {
    // word chars: letters AND underscore (chr(95)) AND digits (Y words like
    // "t0"/"r64" contain digits; the C backend's take_alpha accepts them too
    // via is_alpha... precisely: parser.c is_alpha includes is_digit, so
    // "t0" lexes as one id there as well — parity).
    if (islower(c)) { return 1; }
    else if (isupper(c)) { return 1; }
    else if (ys_eq_lit(c, "_")) { return 1; }
    else { return isdigit(c); }
}

int isalnum(Yv *c) {
    // NOTE: no `||` of bools here — the C VM evaluates both sides eagerly
    // AND the native checker types `||` operands strictly; nested ifs keep
    // both toolchains quiet.
    if (isdigit(c)) { return 1; } else { return isalpha(c); }
}

// Digit of a radix literal (0x.. / 0b..), including `_` separators.
// NOTE: nested ifs, not `||` (see isalnum note).
int is_radix_ch(Yv *c, long radix) {
    int ok = 0;
    if (ys_eq_lit(c, "_")) { ok = 1; ; } else { ; }
    if (radix == 2) {
        if (ys_eq_lit(c, "0")) { ok = 1; ; } else { ; };
        if (ys_eq_lit(c, "1")) { ok = 1; ; } else { ; };
        ;
    } else {
        if (isdigit(c)) { ok = 1; ; } else { ; };
        if (ys_cmp(c, ys("a")) >= 0) {
            if (ys_cmp(c, ys("f")) <= 0) { ok = 1; ; } else { ; };
            ;
        } else { ; };
        if (ys_cmp(c, ys("A")) >= 0) {
            if (ys_cmp(c, ys("F")) <= 0) { ok = 1; ; } else { ; };
            ;
        } else { ; };
        ;
    }
    return ok;
}

int isspace(Yv *c) {
    if (ys_eq_lit(c, " ")) { return 1; }
    else if (ys_eq_lit(c, "\t")) { return 1; }
    else if (ys_eq_lit(c, "\n")) { return 1; }
    else { return ys_eq_lit(c, "\r"); }
}

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
int ispunct(Yv *c) {
    if (ys_eq_lit(c, "(")) { return 1; }
    else if (ys_eq_lit(c, ")")) { return 1; }
    else if (ys_eq_lit(c, "{")) { return 1; }
    else if (ys_eq_lit(c, "}")) { return 1; }
    else if (ys_eq_lit(c, "[")) { return 1; }
    else if (ys_eq_lit(c, "]")) { return 1; }
    else if (ys_eq_lit(c, ",")) { return 1; }
    else if (ys_eq_lit(c, ";")) { return 1; }
    else { return ys_eq_lit(c, ":"); }
}

Yv *mktok(Yv *t, Yv *v, long line, long col) {
    return ym(4, "t", t, "v", v, "line", yv_long(line), "col", yv_long(col));
}

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
// NOTE: nested ifs, not `&&` chains (see isdigit note).
long hexvalx(Yv *c) {
    long o = ys_ord(c);
    if (o >= 48) {
        if (o <= 57) { return o - 48; }
        else if (o >= 65) {
            if (o <= 70) { return o - 65 + 10; }
            else if (o >= 97) {
                if (o <= 102) { return o - 97 + 10; } else { return -1; }
            } else { return -1; }
        } else { return -1; }
    } else { return -1; }
}

// Try to read a two-char operator at position i. Returns the operator or "".
// Maximal munch, like C: `x+++y` is `x ++ + y`. There is no `=+` operator;
// `x =+ y` is `x = +y`.
// NOTE: nested ifs, not `||` chains (see ispunct note).
Yv *twocharop(Yv *src, long i) {
    Yv *two = ys_substr(src, i, 2);
    if (ys_eq_lit(two, "==")) { return two; }
    else if (ys_eq_lit(two, "!=")) { return two; }
    else if (ys_eq_lit(two, "<=")) { return two; }
    else if (ys_eq_lit(two, ">=")) { return two; }
    else if (ys_eq_lit(two, "&&")) { return two; }
    else if (ys_eq_lit(two, "||")) { return two; }
    else if (ys_eq_lit(two, "::")) { return two; }
    else if (ys_eq_lit(two, "..")) { return two; }
    else if (ys_eq_lit(two, "->")) { return two; }
    else if (ys_eq_lit(two, "++")) { return two; }
    else if (ys_eq_lit(two, "--")) { return two; }
    else if (ys_eq_lit(two, "+=")) { return two; }
    else if (ys_eq_lit(two, "-=")) { return two; }
    else if (ys_eq_lit(two, "*=")) { return two; }
    else if (ys_eq_lit(two, "/=")) { return two; }
    else if (ys_eq_lit(two, "%=")) { return two; }
    else { return ys(""); }
}

int issingleop(Yv *c) {
    if (ys_eq_lit(c, "+")) { return 1; }
    else if (ys_eq_lit(c, "-")) { return 1; }
    else if (ys_eq_lit(c, "*")) { return 1; }
    else if (ys_eq(c, slash())) { return 1; }
    else if (ys_eq_lit(c, "%")) { return 1; }
    else if (ys_eq_lit(c, "<")) { return 1; }
    else if (ys_eq_lit(c, ">")) { return 1; }
    else if (ys_eq_lit(c, "=")) { return 1; }
    else if (ys_eq_lit(c, ".")) { return 1; }
    else if (ys_eq_lit(c, "!")) { return 1; }
    else if (ys_eq_lit(c, "&")) { return 1; }
    else { return ys_eq_lit(c, "?"); }
}

// The slash character, built without a literal: Y string literals cannot
// spell it... precisely: they CAN (c == slash-char works in comparisons),
// but a bare slash char inside a comment or adjacent to code confuses the
// dispatch reasoning above, so every slash reference goes through this one
// helper (chr(47)). Single source of truth, zero literal slashes outside
// strings in this file.
Yv *slash(void) { return ys("/"); }

int isdigitch(Yv *c) {
    // single-char predicate on a 1-char string (native-safe: no ord()).
    if (ys_eq_lit(c, "0")) { return 1; }
    else if (ys_eq_lit(c, "1")) { return 1; }
    else if (ys_eq_lit(c, "2")) { return 1; }
    else if (ys_eq_lit(c, "3")) { return 1; }
    else if (ys_eq_lit(c, "4")) { return 1; }
    else if (ys_eq_lit(c, "5")) { return 1; }
    else if (ys_eq_lit(c, "6")) { return 1; }
    else if (ys_eq_lit(c, "7")) { return 1; }
    else if (ys_eq_lit(c, "8")) { return 1; }
    else { return ys_eq_lit(c, "9"); }
}

Yv *tokenize(Yv *src) {
    Yv *toks = yav(0);
    long i = 0;
    long n = yv_len(src);
    long line = 1;
    long col = 1;
    while (i < n) {
        Yv *c = ys_substr(src, i, 1);
        if (isspace(c)) {
            if (ys_eq_lit(c, "\n")) { line = line + 1; col = 1; ; }
            else { col = col + 1; ; }
            i = i + 1;
            ;
        } else if (isdigit(c)) {
            long start = i;
            long startcol = col;
            // 0x../0X.. (hex) and 0b../0B.. (binary) integer literals.
            // NOTE: nested ifs, not `||` (see isalnum note).
            long radix = 0;
            if (ys_eq_lit(c, "0")) {
                Yv *nxt = ys_substr(src, i + 1, 1);
                if (ys_eq_lit(nxt, "x")) { radix = 16; ; } else { ; };
                if (ys_eq_lit(nxt, "X")) { radix = 16; ; } else { ; };
                if (ys_eq_lit(nxt, "b")) { radix = 2; ; } else { ; };
                if (ys_eq_lit(nxt, "B")) { radix = 2; ; } else { ; };
                ;
            } else { ; }
            if (radix > 0) {
                i = i + 2;
                col = col + 2;
                int rdone = 0;
                while (rdone == 0) {
                    if (i < n) {
                        if (is_radix_ch(ys_substr(src, i, 1), radix)) { i = i + 1; col = col + 1; ; }
                        else { rdone = 1; ; };
                        ;
                    } else { rdone = 1; ; }
                };
                ;
            } else {
            int ind = 0;
            while (ind == 0) {
                if (i < n) {
                    if (isdigit(ys_substr(src, i, 1))) { i = i + 1; col = col + 1; ; }
                    else { ind = 1; ; };
                    ;
                } else { ind = 1; ; }
            };
            // optional fractional part (but not '..' range).
            // NOTE: no `&&` (see line-comment note): check the dot, then the
            // lookahead, in nested form.
            if (ys_eq_lit(ys_substr(src, i, 1), ".")) {
                if (!ys_eq_lit(ys_substr(src, i + 1, 1), ".")) {
                    i = i + 1;
                    col = col + 1;
                    int frd = 0;
                    while (frd == 0) {
                        if (i < n) {
                            if (isdigit(ys_substr(src, i, 1))) { i = i + 1; col = col + 1; ; }
                            else { frd = 1; ; };
                            ;
                        } else { frd = 1; ; }
                    };
                    ;
                } else { ; }
                ;
            } else { ; }
            // optional exponent: e / E, an optional sign, then digits. Only
            // consumed when at least one digit follows, so `1e` stays a
            // number followed by an identifier rather than a bad literal.
            Yv *ec = ys_substr(src, i, 1);
            int is_e = 0;
            if (ys_eq_lit(ec, "e")) { is_e = 1; ; } else { ; };
            if (ys_eq_lit(ec, "E")) { is_e = 1; ; } else { ; }
            if (is_e) {
                long esign = 0;
                Yv *sc = ys_substr(src, i + 1, 1);
                if (ys_eq_lit(sc, "+")) { esign = 1; ; } else { ; };
                if (ys_eq_lit(sc, "-")) { esign = 1; ; } else { ; }
                if (isdigit(ys_substr(src, i + 1 + esign, 1))) {
                    i = i + 1 + esign;
                    col = col + 1 + esign;
                    int exd = 0;
                    while (exd == 0) {
                        if (i < n) {
                            if (isdigit(ys_substr(src, i, 1))) { i = i + 1; col = col + 1; ; }
                            else { exd = 1; ; };
                            ;
                        } else { exd = 1; ; }
                    };
                    ;
                } else { ; }
                ;
            } else { ; }
            ;
            }
            toks = ya_push(toks, mktok(ys("num"), ys_substr(src, start, i - start), line, startcol));
            ;
        } else if (isalpha(c)) {
            long start = i;
            long startcol = col;
            int inw = 0;
            while (inw == 0) {
                if (i < n) {
                    if (isalnum(ys_substr(src, i, 1))) { i = i + 1; col = col + 1; ; }
                    else { inw = 1; ; };
                    ;
                } else { inw = 1; ; }
            };
            Yv *word = ys_substr(src, start, i - start);
            Yv *ty = ys("id");
            if (ys_eq_lit(word, "let")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "const")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "def")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "if")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "else")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "while")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "for")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "foreach")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "in")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "return")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "true")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "false")) { ty = ys("kw"); ; }
            else if (ys_eq_lit(word, "null")) { ty = ys("kw"); ; }
            else { ; }
            toks = ya_push(toks, mktok(ty, word, line, startcol));
            ;
        } else if (ys_eq_lit(c, "\"")) {
            // string literal with escapes. NOTE: this arm precedes the slash
            // arms below: every slash inside quotes is consumed here, so the
            // slash arms only ever see real comment openers or operators.
            // Fast path: scan to the closing quote (respecting escapes), extract
            // the raw content with ONE substr, then process escapes only if any
            // backslash is present. Avoids O(n^2) char-by-char concatenation.
            long startline = line;
            long startcol = col;
            i = i + 1;
            col = col + 1;
            long start = i;
            int open = 1;
            int hasesc = 0;
            while (open) {
                if (i < n) {
                    Yv *ch = ys_substr(src, i, 1);
                    if (ys_eq_lit(ch, "\\")) { hasesc = 1; i = i + 2; col = col + 2; ; }
                    else if (ys_eq_lit(ch, "\"")) { open = 0; ; }
                    else {
                        if (ys_eq_lit(ch, "\n")) { line = line + 1; col = 1; ; }
                        else { col = col + 1; ; }
                        i = i + 1;
                        ;
                    };
                    ;
                } else { open = 0; ; }
            };
            if (open) {
                puts_(ys("error: unterminated string literal\n"));
                ;
            } else { ; }
            Yv *raw = ys_substr(src, start, i - start);
            i = i + 1;  // skip closing quote
            col = col + 1;
            Yv *buf = raw;
            if (hasesc) {
                // process escapes into a chunk list + join (O(n))
                Yv *chunks = yav(0);
                long k = 0;
                long rn = yv_len(raw);
                while (k < rn) {
                    Yv *rc = ys_substr(raw, k, 1);
                    if (ys_eq_lit(rc, "\\")) {
                        Yv *esc = ys_substr(raw, k + 1, 1);
                        if (ys_eq_lit(esc, "n")) { chunks = ya_push(chunks, ys("\n")); k = k + 2; ; }
                        else if (ys_eq_lit(esc, "t")) { chunks = ya_push(chunks, ys("\t")); k = k + 2; ; }
                        else if (ys_eq_lit(esc, "r")) { chunks = ya_push(chunks, ys("\r")); k = k + 2; ; }
                        else if (ys_eq_lit(esc, "x")) {
                            // \xHH — two hex digits
                            long h1 = hexvalx(ys_substr(raw, k + 2, 1));
                            long h2 = hexvalx(ys_substr(raw, k + 3, 1));
                            if (h1 >= 0 && h2 >= 0) {
                                chunks = ya_push(chunks, ys_chr(h1 * 16 + h2));
                                k = k + 4;
                                ;
                            } else {
                                chunks = ya_push(chunks, esc);
                                k = k + 2;
                                ;
                            };
                            ;
                        }
                        else { chunks = ya_push(chunks, esc); k = k + 2; ; };
                        ;
                    } else {
                        chunks = ya_push(chunks, rc);
                        k = k + 1;
                        ;
                    };
                };
                buf = ys_join(chunks, ys(""));
                ;
            } else { ; }
            toks = ya_push(toks, mktok(ys("str"), buf, startline, startcol));
            ;
        } else if (ys_eq(c, slash())) {
            // Slash: comment opener, block comment, or division operator.
            // (The string arm above consumed every slash inside quotes, so a
            // slash reaching here is real code.) Look ahead one char:
            // slash-slash = line comment, slash-star = block comment,
            // anything else = division operator. No lone-slash error: the C
            // backend lexes division identically (parser.c skip_spaces skips
            // comments, parse_operator matches division), so parity demands
            // we emit the operator too.
            // NOTE: no `&&` guard (see below) — nested-if form.
            if (ys_eq(ys_substr(src, i + 1, 1), slash())) {
                // line comment
                i = i + 2;
                col = col + 2;
                int done = 0;
                while (done == 0) {
                    if (i < n) {
                        if (!ys_eq_lit(ys_substr(src, i, 1), "\n")) { i = i + 1; col = col + 1; ; }
                        else { done = 1; ; };
                        ;
                    } else { done = 1; ; }
                };
                ;
            } else if (ys_eq_lit(ys_substr(src, i + 1, 1), "*")) {
                i = i + 2;
                col = col + 2;
                int open = 1;
                while (open) {
                    if (i + 1 < n) {
                        if (ys_eq_lit(ys_substr(src, i, 2), "*/")) {
                            i = i + 2;
                            col = col + 2;
                            open = 0;
                            ;
                        } else {
                            Yv *ch = ys_substr(src, i, 1);
                            if (ys_eq_lit(ch, "\n")) { line = line + 1; col = 1; ; }
                            else { col = col + 1; ; }
                            i = i + 1;
                            ;
                        };
                        ;
                    } else { open = 0; ; }
                };
                if (open) {
                    puts_(ys("error: unterminated block comment\n"));
                    ;
                } else { ; }
                ;
            } else {
                // division operator or `/=` (not a comment opener). The
                // comment dispatch above owns the `/` branch, so `/=` has
                // to be recognized HERE — the generic twocharop dispatch
                // below never sees it.
                Yv *two = twocharop(src, i);
                if (ys_eq_lit(two, "/=")) {
                    toks = ya_push(toks, mktok(ys("op"), two, line, col));
                    i = i + 2;
                    col = col + 2;
                    ;
                } else {
                    toks = ya_push(toks, mktok(ys("op"), slash(), line, col));
                    i = i + 1;
                    col = col + 1;
                    ;
                };
                ;
            }
        } else {
            // operator / punct / unknown-char dispatch. NOTE: bound once —
            // twocharop(src, i) inline inside a call misparses on the C
            // backend (it reads `f(g(x), ...)` args with dot/index shapes
            // as field access; see native.y strip_ns note).
            Yv *two = twocharop(src, i);
            if (!ys_eq_lit(two, "")) {
                toks = ya_push(toks, mktok(ys("op"), two, line, col));
                i = i + 2;
                col = col + 2;
                ;
            } else if (issingleop(c)) {
                toks = ya_push(toks, mktok(ys("op"), c, line, col));
                i = i + 1;
                col = col + 1;
                ;
            } else if (ispunct(c)) {
                toks = ya_push(toks, mktok(ys("punct"), c, line, col));
                i = i + 1;
                col = col + 1;
                ;
            } else {
                // unknown char — skip
                i = i + 1;
                col = col + 1;
                ;
            };
        }
    }
    toks = ya_push(toks, mktok(ys("eof"), ys(""), line, col));
    return toks;
}

/* export { tokenize }; */
