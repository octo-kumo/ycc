/* lexer.c — tokenize a Y source string into a list of token maps.
 * 1:1 C copy of src/y/lexer.y (see PORTING.md).
 * Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
 * Token types: id, num, str, bstr, char, op, punct, kw, eof, and ferr -- a
 * malformed literal (a broken f-string, lex_fstring; a radix prefix without
 * digits), v its error message.
 *
 * NOTE: short underscore-free names (isdigit/isalpha/...) — see below. */

#include "lexer.h"

int isdigit(Yv *c) {
    // Range compares on the 1-char string, not ord(c): ord goes through
    // bytes(), which allocates a copy of the string per character, and the
    // lexer classifies every character of the source. Comparisons land in
    // y_str_eq/y_str_cmp — byte primitives, no allocation.
    return ys_cmp(c, ys("0")) >= 0 && ys_cmp(c, ys("9")) <= 0;
}

int isupper(Yv *c) {
    return ys_cmp(c, ys("A")) >= 0 && ys_cmp(c, ys("Z")) <= 0;
}

int islower(Yv *c) {
    return ys_cmp(c, ys("a")) >= 0 && ys_cmp(c, ys("z")) <= 0;
}

int isalpha(Yv *c) {
    // word chars: letters AND underscore (chr(95)) AND digits (Y words like
    // "t0"/"r64" contain digits; the C backend's take_alpha accepts them too
    // via is_alpha... precisely: parser.c is_alpha includes is_digit, so
    // "t0" lexes as one id there as well — parity).
    return islower(c) || isupper(c) || ys_eq_lit(c, "_") || isdigit(c);
}

int isalnum(Yv *c) {
    return isdigit(c) || isalpha(c);
}

// Digit of a radix literal (0x.. / 0b..), including `_` separators.
int is_radix_ch(Yv *c, long radix) {
    if (ys_eq_lit(c, "_")) { return 1; }
    else if (radix == 2) { return ys_eq_lit(c, "0") || ys_eq_lit(c, "1"); }
    else { return isdigit(c) ||
        (ys_cmp(c, ys("a")) >= 0 && ys_cmp(c, ys("f")) <= 0) ||
        (ys_cmp(c, ys("A")) >= 0 && ys_cmp(c, ys("F")) <= 0); }
}

// A decimal literal's text without its `_` digit separators: its num token
// carries this, so whatever reads the literal (tonum, norm_num, the float
// helpers) sees plain digits. A radix literal keeps them (norm_num skips
// them).
Yv *strip_seps(Yv *s) {
    if (ys_index_of(s, ys("_")) < 0) { return s; }
    else { return ys_join(ys_split(s, ys("_")), ys("")); }
}

int isspace(Yv *c) {
    return ys_eq_lit(c, " ") || ys_eq_lit(c, "\t") ||
           ys_eq_lit(c, "\n") || ys_eq_lit(c, "\r");
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
int ispunct(Yv *c) {
    return ys_eq_lit(c, "(") || ys_eq_lit(c, ")") ||
           ys_eq_lit(c, "{") || ys_eq_lit(c, "}") ||
           ys_eq_lit(c, "[") || ys_eq_lit(c, "]") ||
           ys_eq_lit(c, ",") || ys_eq_lit(c, ";") ||
           ys_eq_lit(c, ":");
}

static Yv *unescape(Yv *raw, int braces);

// Scan a quoted literal at src[i] (a `"` or `'` quote): returns the
// decoded text and the position just past the closing quote. Escapes:
// \n \t \r, \xHH, and `\<c>` drops the backslash (the Y literal rules).
Yv *lex_quoted(Yv *src, long i, long line, long col) {
    Yv *q = ys_slice(src, i, i + 1);
    long n = yv_len(src);
    i = i + 1;
    col = col + 1;
    long start = i;
    int open = 1;
    int closed = 0;
    int hasesc = 0;
    while (open) {
        if (i < n) {
            Yv *ch = ys_slice(src, i, i + 1);
            if (ys_eq_lit(ch, "\\")) { hasesc = 1; i = i + 2; col = col + 2; ; }
            else if (ys_eq(ch, q)) { open = 0; closed = 1; ; }
            else {
                if (ys_eq_lit(ch, "\n")) { line = line + 1; col = 1; ; }
                else { col = col + 1; ; };
                i = i + 1;
                ;
            };
            ;
        } else { open = 0; ; }
    };
    if (closed) {
        ;
    } else {
        /* ran off the end with the quote still open */
        puts_(ys("error: unterminated string literal\n"));
        exit_(1);
        ;
    }
    Yv *raw = ys_slice(src, start, i);
    i = i + 1;  // skip closing quote
    col = col + 1;
    Yv *buf = raw;
    if (hasesc) {
        buf = unescape(raw, 0);
        ;
    } else { ; }
    return yr(4, "text", buf, "end", yv_long(i), "line", yv_long(line), "col", yv_long(col));
}

/* A literal's text from its raw source: \n \t \r, \xHH, and `\<c>` drops
 * the backslash (the Y literal rules). In an f-string (`braces`) `{{` and
 * `}}` are one brace each -- fstr_walk lets no single brace through. */
static Yv *unescape(Yv *raw, int braces) {
    /* a chunk list + join (O(n)) */
    Yv *chunks = yav(0);
    long k = 0;
    long rn = yv_len(raw);
    while (k < rn) {
        Yv *rc = ys_slice(raw, k, k + 1);
        if (ys_eq_lit(rc, "\\")) {
            Yv *esc = ys_slice(raw, k + 1, k + 2);
            if (ys_eq_lit(esc, "n")) { chunks = ya_push(chunks, ys("\n")); k = k + 2; ; }
            else if (ys_eq_lit(esc, "t")) { chunks = ya_push(chunks, ys("\t")); k = k + 2; ; }
            else if (ys_eq_lit(esc, "r")) { chunks = ya_push(chunks, ys("\r")); k = k + 2; ; }
            else if (ys_eq_lit(esc, "x")) {
                /* \xHH -- two hex digits */
                long h1 = hexvalx(ys_slice(raw, k + 2, k + 3));
                long h2 = hexvalx(ys_slice(raw, k + 3, k + 4));
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
        } else if (braces && (ys_eq_lit(rc, "{") || ys_eq_lit(rc, "}"))) {
            chunks = ya_push(chunks, rc);
            k = k + 2;
            ;
        } else {
            chunks = ya_push(chunks, rc);
            k = k + 1;
            ;
        };
    };
    return ys_join(chunks, ys(""));
}

/* ── f-strings ────────────────────────────────────────────────────────────
 * f"x = {x}, mean {total / n:.2f}" -- text with fields in braces. A field
 * is one expression, then optionally `:` and a format spec running to the
 * closing brace (types.y fmt_spec). `{{` and `}}` are literal braces, and
 * a backslash escapes as in any literal (`\{` too). The expression ends at
 * the first `}` or `:` outside brackets and literals -- a `:` closing a
 * `c ? a : b` excepted -- so strings, slices and records need no escaping
 * in it: f"{d["k"]}", f"{s[1:3]}", f"{n == 1 ? "" : "s"}". */

/* A byte of an identifier-shaped word (isalnum, on a byte). */
static int wordbyte(long c) {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ||
           (c >= 48 && c <= 57) || c == 95;
}

/* Just past the literal whose opening quote is src[q] (a backslash escapes
 * the byte after it); len(src) when it never closes. */
static long lit_end(Yv *src, long q) {
    long n = yv_len(src);
    long qc = ys_byte_at(src, q);
    long i = q + 1;
    long end = n;
    int open = 1;
    while (open && i < n) {
        long c = ys_byte_at(src, i);
        if (c == 92) { i = i + 2; ; }
        else if (c == qc) { end = i + 1; open = 0; ; }
        else { i = i + 1; ; };
    };
    return end;
}

/* Where the expression of the f-string field starting at src[lo] ends: the
 * first `}` or `:` outside brackets and literals (but a `:` that closes a
 * `?`), or a `,` `;` or unmatched `)` `]` there, which fstr_walk rejects;
 * len(src) when the source runs out first. */
static long fstr_expr_end(Yv *src, long lo) {
    long n = yv_len(src);
    long depth = 0;
    long tern = 0;
    long i = lo;
    long stop = n;
    int go = 1;
    while (go && i < n) {
        long c = ys_byte_at(src, i);
        if (c == 34 || c == 39) {
            if (c == 34 && i > lo && ys_byte_at(src, i - 1) == 102 &&
                (i - 1 == lo || !wordbyte(ys_byte_at(src, i - 2)))) {
                /* a nested f"..." */
                i = yv_l(yr_get(fstr_walk(src, i), "end"));
                ;
            } else {
                i = lit_end(src, i);
                ;
            };
            ;
        } else if (c == 40 || c == 91 || c == 123) {
            depth = depth + 1;
            i = i + 1;
            ;
        } else if (depth > 0) {
            if (c == 41 || c == 93 || c == 125) { depth = depth - 1; ; } else { ; };
            i = i + 1;
            ;
        } else if (c == 63) {
            tern = tern + 1;
            i = i + 1;
            ;
        } else if (c == 58 && tern > 0) {
            tern = tern - 1;
            i = i + 1;
            ;
        } else if (c == 125 || c == 58 || c == 44 || c == 59 || c == 41 || c == 93) {
            stop = i;
            go = 0;
            ;
        } else {
            i = i + 1;
            ;
        };
    };
    return stop;
}

/* Whether src[lo:hi] is all blanks. */
static int fstr_blank(Yv *src, long lo, long hi) {
    long i = lo;
    int blank = 1;
    while (blank && i < hi) {
        long c = ys_byte_at(src, i);
        blank = c == 32 || c == 9 || c == 10 || c == 13;
        i = i + 1;
        ;
    };
    return blank;
}

/* Walk the f-string whose opening quote is src[q]: where it ends (past the
 * closing quote), what is wrong with it ("" when nothing is) and where, and
 * its fields, four numbers each: the expression is src[lo:hi], the spec
 * src[slo:shi] (both -1 without a `:`). The lexer lowers what this finds
 * (lex_fstring) and native.y's splice scan reads the same fields as code
 * (words_scan), so the two always agree. A broken f-string ends where a
 * plain literal would. */
Yv *fstr_walk(Yv *src, long q) {
    long n = yv_len(src);
    Yv *fields = yav(0);
    Yv *err = ys("");
    long at = q;
    long i = q + 1;
    int open = 1;
    while (open) {
        if (i >= n) {
            err = ys("unterminated f-string");
            open = 0;
            ;
        } else {
            long c = ys_byte_at(src, i);
            if (c == 92) {
                i = i + 2;
                ;
            } else if (c == 34) {
                i = i + 1;
                open = 0;
                ;
            } else if ((c == 123 || c == 125) && i + 1 < n &&
                       ys_byte_at(src, i + 1) == c) {
                i = i + 2;
                ;
            } else if (c == 125) {
                err = ys("single '}' in an f-string (a literal brace is '}}')");
                at = i;
                open = 0;
                ;
            } else if (c == 123) {
                long lo = i + 1;
                long hi = fstr_expr_end(src, lo);
                long hc = 0;
                if (hi < n) { hc = ys_byte_at(src, hi); ; } else { ; };
                if (hc != 125 && hc != 58) {
                    if (hi >= n) {
                        err = ys("unterminated f-string field");
                        at = i;
                        ;
                    } else {
                        err = ys_cat(
                            ys_cat(ys("an f-string field is one expression, got '"),
                                   ys_slice(src, hi, hi + 1)),
                            ys("'"));
                        at = hi;
                        ;
                    };
                    open = 0;
                    ;
                } else if (fstr_blank(src, lo, hi)) {
                    err = ys("empty f-string field");
                    at = i;
                    open = 0;
                    ;
                } else if (hc == 125) {
                    fields = ya_push(fields, yv_long(lo));
                    fields = ya_push(fields, yv_long(hi));
                    fields = ya_push(fields, yv_long(0 - 1));
                    fields = ya_push(fields, yv_long(0 - 1));
                    i = hi + 1;
                    ;
                } else {
                    /* the spec: up to the closing brace */
                    long e = hi + 1;
                    while (e < n && ys_byte_at(src, e) != 125 &&
                           ys_byte_at(src, e) != 123 &&
                           ys_byte_at(src, e) != 34) {
                        e = e + 1;
                        ;
                    };
                    if (e < n && ys_byte_at(src, e) == 125) {
                        fields = ya_push(fields, yv_long(lo));
                        fields = ya_push(fields, yv_long(hi));
                        fields = ya_push(fields, yv_long(hi + 1));
                        fields = ya_push(fields, yv_long(e));
                        i = e + 1;
                        ;
                    } else {
                        if (e < n && ys_byte_at(src, e) == 123) {
                            err = ys("a format spec cannot hold '{'");
                            at = e;
                            ;
                        } else {
                            err = ys("unterminated f-string field");
                            at = i;
                            ;
                        };
                        open = 0;
                        ;
                    };
                    ;
                };
                ;
            } else {
                i = i + 1;
                ;
            };
            ;
        };
        ;
    };
    long end = i;
    if (!ys_eq_lit(err, "")) { end = lit_end(src, q); ; } else { ; };
    return yr(4, "end", yv_long(end), "err", err, "at", yv_long(at), "fields", fields);
}

/* The position (line, col) moves to over src[a:b]. */
static Yv *fstr_adv(Yv *src, long a, long b, long line, long col) {
    long ln = line;
    long cl = col;
    long i = a;
    while (i < b) {
        if (ys_byte_at(src, i) == 10) { ln = ln + 1; cl = 1; ; } else { cl = cl + 1; ; };
        i = i + 1;
        ;
    };
    return yr(2, "line", yv_long(ln), "col", yv_long(cl));
}

/* The tokens of the f-string whose `f` is at (line, col) and whose opening
 * quote is src[q], appended to toks; returns where lexing goes on. It is a
 * concatenation, each field a call of `#fmt` -- a name no program can bind,
 * which types.y (typeof_fmt) checks and native.y (gen_fmt) emits:
 *   f"a{x}b{y:>5}"  ->  ( "a" + #fmt(x, "") + "b" + #fmt(y, ">5") )
 * A field's expression is tokenized on its own, its tokens moved to where
 * it stands; the rest sits at the field's `{`. Without fields it is a plain
 * string; a broken one is an `ferr` token, which the parser turns into an
 * error where the walk stopped. */
static Yv *lex_fstring(Yv *src, long q, long line, long col, Yv *toks) {
    Yv *w = fstr_walk(src, q);
    Yv *fs = yr_get(w, "fields");
    if (!ys_eq_lit(yr_get(w, "err"), "")) {
        Yv *ep = fstr_adv(src, q - 1, yv_l(yr_get(w, "at")), line, col);
        toks = ya_push(toks, mktok(ys("ferr"), yr_get(w, "err"),
                                  yv_l(yr_get(ep, "line")),
                                  yv_l(yr_get(ep, "col"))));
        ;
    } else if (yv_len(fs) == 0) {
        toks = ya_push(toks, mktok(ys("str"),
                                   unescape(ys_slice(src, q + 1,
                                                     yv_l(yr_get(w, "end")) - 1), 1),
                                   line, col));
        ;
    } else {
        toks = ya_push(toks, mktok(ys("punct"), ys("("), line, col));
        long from = q + 1;
        long at = q - 1;
        long bl = line;
        long bc = col;
        long k = 0;
        while (k < yv_len(fs)) {
            long lo = yv_l(ya_get(fs, k));
            long hi = yv_l(ya_get(fs, k + 1));
            long slo = yv_l(ya_get(fs, k + 2));
            Yv *bp = fstr_adv(src, at, lo - 1, bl, bc);
            at = lo - 1;
            bl = yv_l(yr_get(bp, "line"));
            bc = yv_l(yr_get(bp, "col"));
            if (k > 0) { toks = ya_push(toks, mktok(ys("op"), ys("+"), bl, bc)); ; } else { ; };
            if (lo - 1 > from) {
                toks = ya_push(toks, mktok(ys("str"),
                                           unescape(ys_slice(src, from, lo - 1), 1),
                                           bl, bc));
                toks = ya_push(toks, mktok(ys("op"), ys("+"), bl, bc));
                ;
            } else { ; };
            toks = ya_push(toks, mktok(ys("id"), ys("#fmt"), bl, bc));
            toks = ya_push(toks, mktok(ys("punct"), ys("("), bl, bc));
            Yv *sub = tokenize(ys_slice(src, lo, hi));
            long j = 0;
            while (j + 1 < yv_len(sub)) {
                Yv *tk = ya_get(sub, j);
                if (yv_l(yr_get(tk, "line")) == 1) {
                    toks = ya_push(toks,
                                   mktok(yr_get(tk, "t"), yr_get(tk, "v"), bl,
                                         bc + yv_l(yr_get(tk, "col"))));
                    ;
                } else {
                    toks = ya_push(toks,
                                   mktok(yr_get(tk, "t"), yr_get(tk, "v"),
                                         bl + yv_l(yr_get(tk, "line")) - 1,
                                         yv_l(yr_get(tk, "col"))));
                    ;
                };
                j = j + 1;
                ;
            };
            toks = ya_push(toks, mktok(ys("punct"), ys(","), bl, bc));
            if (slo >= 0) {
                toks = ya_push(toks, mktok(ys("str"),
                                           ys_slice(src, slo,
                                                    yv_l(ya_get(fs, k + 3))),
                                           bl, bc));
                from = yv_l(ya_get(fs, k + 3)) + 1;
                ;
            } else {
                toks = ya_push(toks, mktok(ys("str"), ys(""), bl, bc));
                from = hi + 1;
                ;
            };
            toks = ya_push(toks, mktok(ys("punct"), ys(")"), bl, bc));
            k = k + 4;
            ;
        };
        long end = yv_l(yr_get(w, "end"));
        if (end - 1 > from) {
            toks = ya_push(toks, mktok(ys("op"), ys("+"), bl, bc));
            toks = ya_push(toks, mktok(ys("str"),
                                       unescape(ys_slice(src, from, end - 1), 1),
                                       bl, bc));
            ;
        } else { ; };
        toks = ya_push(toks, mktok(ys("punct"), ys(")"), bl, bc));
        ;
    };
    Yv *e = fstr_adv(src, q - 1, yv_l(yr_get(w, "end")), line, col);
    return yr(3, "end", yr_get(w, "end"), "line", yr_get(e, "line"), "col", yr_get(e, "col"));
}

Yv *mktok(Yv *t, Yv *v, long line, long col) {
    return yr(4, "t", t, "v", v, "line", yv_long(line), "col", yv_long(col));
}

// Value of a single hex digit char (0-15), or -1 if not a hex digit.
long hexvalx(Yv *c) {
    long o = ys_ord(c);
    if (o >= 48 && o <= 57) { return o - 48; }
    else if (o >= 65 && o <= 70) { return o - 65 + 10; }
    else if (o >= 97 && o <= 102) { return o - 97 + 10; }
    else { return -1; }
}

// Try to read an operator of two or more chars at position i (c is the char
// there): the longest one, or "". Maximal munch, like C: `x+++y` is
// `x ++ + y` and `a>>>=b` is `a >>>= b`. There is no `=+` operator;
// `x =+ y` is `x = +y`. Only the shifts are longer than two chars, so only
// `<` and `>` look further ahead.
Yv *multicharop(Yv *src, long i, Yv *c) {
    if (ys_eq_lit(c, "<") || ys_eq_lit(c, ">")) {
        Yv *four = ys_slice(src, i, i + 4);
        Yv *three = ys_slice(src, i, i + 3);
        if (ys_eq_lit(four, ">>>=")) { return four; }
        else if (ys_eq_lit(three, ">>>") || ys_eq_lit(three, ">>=") ||
                 ys_eq_lit(three, "<<=")) { return three; }
        else { return twocharop(src, i); }
    } else {
        return twocharop(src, i);
    }
}

// Try to read a two-char operator at position i. Returns the operator or "".
Yv *twocharop(Yv *src, long i) {
    Yv *two = ys_slice(src, i, i + 2);
    if (ys_eq_lit(two, "==") || ys_eq_lit(two, "!=") ||
        ys_eq_lit(two, "<=") || ys_eq_lit(two, ">=") ||
        ys_eq_lit(two, "&&") || ys_eq_lit(two, "||") ||
        ys_eq_lit(two, "::") || ys_eq_lit(two, "..") ||
        ys_eq_lit(two, "->") || ys_eq_lit(two, "=>") ||
        ys_eq_lit(two, "++") || ys_eq_lit(two, "--") ||
        ys_eq_lit(two, "+=") || ys_eq_lit(two, "-=") ||
        ys_eq_lit(two, "*=") || ys_eq_lit(two, "/=") ||
        ys_eq_lit(two, "%=") || ys_eq_lit(two, "&=") ||
        ys_eq_lit(two, "|=") || ys_eq_lit(two, "^=") ||
        ys_eq_lit(two, "<<") || ys_eq_lit(two, ">>")) { return two; }
    else { return ys(""); }
}

int issingleop(Yv *c) {
    return ys_eq_lit(c, "+") || ys_eq_lit(c, "-") ||
           ys_eq_lit(c, "*") || ys_eq(c, slash()) ||
           ys_eq_lit(c, "%") || ys_eq_lit(c, "<") ||
           ys_eq_lit(c, ">") || ys_eq_lit(c, "=") ||
           ys_eq_lit(c, ".") || ys_eq_lit(c, "!") ||
           ys_eq_lit(c, "&") || ys_eq_lit(c, "?") || ys_eq_lit(c, "|") ||
           ys_eq_lit(c, "^") || ys_eq_lit(c, "~");
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
        Yv *c = ys_slice(src, i, i + 1);
        if (isspace(c)) {
            if (ys_eq_lit(c, "\n")) { line = line + 1; col = 1; ; }
            else { col = col + 1; ; }
            i = i + 1;
            ;
        } else if (isdigit(c)) {
            long start = i;
            long startcol = col;
            // 0x../0X.. (hex) and 0b../0B.. (binary) integer literals.
            long radix = 0;
            if (ys_eq_lit(c, "0")) {
                Yv *nxt = ys_slice(src, i + 1, i + 2);
                if (ys_eq_lit(nxt, "x") || ys_eq_lit(nxt, "X")) { radix = 16; }
                else if (ys_eq_lit(nxt, "b") || ys_eq_lit(nxt, "B")) { radix = 2; }
            }
            // the message of a malformed literal (an ferr token), or ""
            Yv *err = ys("");
            if (radix > 0) {
                i = i + 2;
                col = col + 2;
                int digits = 0;
                int rdone = 0;
                while (rdone == 0) {
                    if (i < n) {
                        Yv *rc = ys_slice(src, i, i + 1);
                        if (is_radix_ch(rc, radix)) {
                            if (!ys_eq_lit(rc, "_")) { digits = 1; }
                            i = i + 1;
                            col = col + 1;
                        } else { rdone = 1; ; };
                        ;
                    } else { rdone = 1; ; }
                };
                if (!digits) {
                    // A prefix without a digit (`0x`, `0b_`, `0b2`) is no
                    // number: the word characters after it are taken into
                    // the bad literal, reported once, where it starts.
                    while (i < n && isalnum(ys_slice(src, i, i + 1))) { i = i + 1; col = col + 1; }
                    if (radix == 16) { err = ys_cat(ys_cat(ys("hex literal '"), ys_slice(src, start, i)), ys("' has no digits")); }
                    else { err = ys_cat(ys_cat(ys("binary literal '"), ys_slice(src, start, i)), ys("' has no digits")); }
                }
                ;
            } else {
            // The first digit is already known from the branch condition.
            // After the first digit of each part (whole, fraction,
            // exponent) `_` may separate digits: 1_000_000, 0.000_1.
            i = i + 1;
            col = col + 1;
            int ind = 0;
            while (ind == 0) {
                if (i < n) {
                    Yv *dc = ys_slice(src, i, i + 1);
                    if (isdigit(dc) || ys_eq_lit(dc, "_")) { i = i + 1; col = col + 1; ; }
                    else { ind = 1; ; };
                    ;
                } else { ind = 1; ; }
            };
            // optional fractional part (but not '..' range).
            if (ys_eq_lit(ys_slice(src, i, i + 1), ".") &&
                !ys_eq_lit(ys_slice(src, i + 1, i + 2), ".")) {
                i = i + 1;
                col = col + 1;
                long fs = i;
                int frd = 0;
                while (frd == 0) {
                    if (i < n) {
                        Yv *fc = ys_slice(src, i, i + 1);
                        if (isdigit(fc) || (ys_eq_lit(fc, "_") && i > fs)) { i = i + 1; col = col + 1; ; }
                        else { frd = 1; ; };
                        ;
                    } else { frd = 1; ; }
                };
            }
            // optional exponent: e / E, an optional sign, then digits. Only
            // consumed when at least one digit follows, so `1e` stays a
            // number followed by an identifier rather than a bad literal.
            Yv *ec = ys_slice(src, i, i + 1);
            if (ys_eq_lit(ec, "e") || ys_eq_lit(ec, "E")) {
                long esign = 0;
                Yv *sc = ys_slice(src, i + 1, i + 2);
                if (ys_eq_lit(sc, "+") || ys_eq_lit(sc, "-")) { esign = 1; }
                if (isdigit(ys_slice(src, i + 1 + esign, i + 2 + esign))) {
                    i = i + 1 + esign;
                    col = col + 1 + esign;
                    int exd = 0;
                    while (exd == 0) {
                        if (i < n) {
                            Yv *xc = ys_slice(src, i, i + 1);
                            if (isdigit(xc) || ys_eq_lit(xc, "_")) { i = i + 1; col = col + 1; ; }
                            else { exd = 1; ; };
                            ;
                        } else { exd = 1; ; }
                    };
                    ;
                }
            }
            }
            Yv *txt = ys_slice(src, start, i);
            if (!ys_eq_lit(err, "")) {
                toks = ya_push(toks, mktok(ys("ferr"), err, line, startcol));
            } else {
                if (radix == 0) { txt = strip_seps(txt); }
                toks = ya_push(toks, mktok(ys("num"), txt, line, startcol));
            }
            ;
        } else if (isalpha(c)) {
            long start = i;
            long startcol = col;
            // The first character is already known to be a word character.
            i = i + 1;
            col = col + 1;
            int inw = 0;
            while (inw == 0) {
                if (i < n) {
                    if (isalnum(ys_slice(src, i, i + 1))) { i = i + 1; col = col + 1; ; }
                    else { inw = 1; ; };
                    ;
                } else { inw = 1; ; }
            };
            Yv *word = ys_slice(src, start, i);
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
            else { ; }
            if (ys_eq_lit(word, "b")) {
                // b"..." / b'...' -- a byte-string literal: the same type
                // as [byte], spelled like a Python bytes literal.
                long bline = line;
                Yv *qch = ys_slice(src, i, i + 1);
                if (ys_eq_lit(qch, "\"")) {
                    Yv *bq = lex_quoted(src, i, line, col);
                    i = yv_l(yr_get(bq, "end"));
                    line = yv_l(yr_get(bq, "line"));
                    col = yv_l(yr_get(bq, "col"));
                    toks = ya_push(toks, mktok(ys("bstr"), yr_get(bq, "text"), bline, startcol));
                    ;
                } else if (ys_eq_lit(qch, "'")) {
                    Yv *bq2 = lex_quoted(src, i, line, col);
                    i = yv_l(yr_get(bq2, "end"));
                    line = yv_l(yr_get(bq2, "line"));
                    col = yv_l(yr_get(bq2, "col"));
                    toks = ya_push(toks, mktok(ys("bstr"), yr_get(bq2, "text"), bline, startcol));
                    ;
                } else {
                    toks = ya_push(toks, mktok(ty, word, line, startcol));
                    ;
                };
                ;
            } else if (ys_eq_lit(word, "c") && ys_eq_lit(ys_slice(src, i, i + 1), "'")) {
                // c'a' -- a character literal: one byte, typed `byte`.
                long cline = line;
                Yv *cq = lex_quoted(src, i, line, col);
                i = yv_l(yr_get(cq, "end"));
                line = yv_l(yr_get(cq, "line"));
                col = yv_l(yr_get(cq, "col"));
                toks = ya_push(toks, mktok(ys("char"), yr_get(cq, "text"), cline, startcol));
                ;
            } else if (ys_eq_lit(word, "f") &&
                       ys_eq_lit(ys_slice(src, i, i + 1), "\"")) {
                /* f"..." -- an f-string (lex_fstring) */
                Yv *fq = lex_fstring(src, i, line, startcol, toks);
                i = yv_l(yr_get(fq, "end"));
                line = yv_l(yr_get(fq, "line"));
                col = yv_l(yr_get(fq, "col"));
                ;
            } else {
                toks = ya_push(toks, mktok(ty, word, line, startcol));
                ;
            }
            ;
        } else if (ys_eq_lit(c, "\"")) {
            // string literal with escapes. NOTE: this arm precedes the slash
            // arms below: every slash inside quotes is consumed here, so the
            // slash arms only ever see real comment openers or operators.
            long startline = line;
            long startcol = col;
            Yv *q = lex_quoted(src, i, line, col);
            i = yv_l(yr_get(q, "end"));
            line = yv_l(yr_get(q, "line"));
            col = yv_l(yr_get(q, "col"));
            toks = ya_push(toks, mktok(ys("str"), yr_get(q, "text"), startline, startcol));
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
            if (ys_eq(ys_slice(src, i + 1, i + 2), slash())) {
                // line comment
                i = i + 2;
                col = col + 2;
                int done = 0;
                while (done == 0) {
                    if (i < n) {
                        if (!ys_eq_lit(ys_slice(src, i, i + 1), "\n")) { i = i + 1; col = col + 1; ; }
                        else { done = 1; ; };
                        ;
                    } else { done = 1; ; }
                };
                ;
            } else if (ys_eq_lit(ys_slice(src, i + 1, i + 2), "*")) {
                i = i + 2;
                col = col + 2;
                int open = 1;
                int closed = 0;
                while (open) {
                    if (i + 1 < n) {
                        if (ys_eq_lit(ys_slice(src, i, i + 2), "*/")) {
                            i = i + 2;
                            col = col + 2;
                            open = 0;
                            closed = 1;
                            ;
                        } else {
                            Yv *ch = ys_slice(src, i, i + 1);
                            if (ys_eq_lit(ch, "\n")) { line = line + 1; col = 1; ; }
                            else { col = col + 1; ; }
                            i = i + 1;
                            ;
                        };
                        ;
                    } else { open = 0; ; }
                };
                if (!closed) {
                    /* ran off the end with the comment still open: fatal,
                     * like an unterminated string (the rest of the file
                     * was silently swallowed) */
                    puts_(ys("error: unterminated block comment\n"));
                    exit_(1);
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
            // multicharop(src, i, c) inline inside a call misparses on the C
            // backend (it reads `f(g(x), ...)` args with dot/index shapes
            // as field access; see native.y strip_ns note).
            Yv *op = multicharop(src, i, c);
            if (!ys_eq_lit(op, "")) {
                toks = ya_push(toks, mktok(ys("op"), op, line, col));
                i = i + yv_len(op);
                col = col + yv_len(op);
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
                // A character no token starts with: passed on as an
                // operator nothing accepts, so the parser reports it.
                toks = ya_push(toks, mktok(ys("op"), c, line, col));
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
