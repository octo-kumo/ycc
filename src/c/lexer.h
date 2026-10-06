/* lexer.h — tokenize a Y source string into a list of token maps.
 * 1:1 C copy of src/y/lexer.y (see PORTING.md).
 * Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
 * Token types: id, num, str, op, punct, kw, ferr, eof. */
#ifndef LEXER_H
#define LEXER_H

#include "ylong.h"
#include "yv.h"

/* <ctype.h> FIRST, before the renames below. On Windows a later <windows.h>
 * (host.h) pulls <ctype.h> in again, and if it arrives after these `#define`s
 * its `int isalpha(int)` declaration is macro-expanded into a second
 * `y_lex_isalpha` with the wrong signature. The header's include guard then
 * makes the later inclusion a no-op, so there is exactly one declaration of
 * each real ctype name and one of each lexer name. */
#include <ctype.h>

/* glibc's <ctype.h> defines all seven as macros too, so the renames below
 * would be "redefined" warnings (they were). Undefine them first: after this
 * the Y spellings win, which is the point. */
#undef isdigit
#undef isupper
#undef islower
#undef isalpha
#undef isalnum
#undef isspace
#undef ispunct

/* NOTE: isdigit/isupper/islower/isalpha/isalnum/isspace/ispunct are the
 * exact Y names of this module's defs (see lexer.y), but C's <ctype.h>
 * reserves all seven as builtin function names and gcc warns on ANY
 * redeclaration of those (-Wbuiltin-declaration-mismatch) even without
 * <ctype.h> included. The defs and call sites keep their Y spellings;
 * these renames map them to unique C symbols. They stay defined after
 * this header (lexer.c depends on it). No other module uses these
 * identifiers (they are lexer.y-internal helpers). */
#define isdigit y_lex_isdigit
#define isupper y_lex_isupper
#define islower y_lex_islower
#define isalpha y_lex_isalpha
#define isalnum y_lex_isalnum
#define isspace y_lex_isspace
#define ispunct y_lex_ispunct

int isdigit(ylong c);                 /* (c: byte) -> bool */
int isupper(ylong c);                 /* (c: byte) -> bool */
int islower(ylong c);                 /* (c: byte) -> bool */
int isalpha(ylong c);                 /* (c: byte) -> bool */
int isalnum(ylong c);                 /* (c: byte) -> bool */
int is_radix_ch(ylong c, ylong radix); /* (c: byte, radix: long) -> bool */
Yv *strip_seps(Yv *s);               /* (s: str) -> str */
int isspace(ylong c);                 /* (c: byte) -> bool */
int ispunct(ylong c);                 /* (c: byte) -> bool */
Yv *lex_quoted(Yv *src, ylong i, ylong line, ylong col, Yv *what);
                                     /* -> { text: str, end: long, line: long, col: long, err: str } */
ylong lit_end(Yv *src, ylong q, ylong *closed);
                                     /* (src: str, q: long, closed: [long]) -> long */
Yv *mktok(Yv *t, Yv *v, ylong line, ylong col);
                                     /* -> { t: str, v: str, line: long, col: long } */
ylong hexvalx(Yv *c);                 /* (c: str) -> long */
Yv *multicharop(Yv *src, ylong i, Yv *c);
                                     /* (src: str, i: long, c: str) -> str */
Yv *twocharop(Yv *src, ylong i);      /* (src: str, i: long) -> str */
int issingleop(ylong c);              /* (c: byte) -> bool */
Yv *slash(void);                     /* () -> str */
ylong slashb(void);                   /* () -> byte */
int isdigitch(ylong c);               /* (c: byte) -> bool */
Yv *tokenize(Yv *src);               /* (src: str) -> [{ t: str, v: str, line: long, col: long }] */
Yv *fstr_walk(Yv *src, ylong q);      /* (src: str, q: long) -> { end: long, err: str, at: long, fields: [long] } */

#endif /* LEXER_H */
