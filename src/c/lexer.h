/* lexer.h — tokenize a Y source string into a list of token maps.
 * 1:1 C copy of src/y/lexer.y (see PORTING.md).
 * Each token is { t: <type>, v: <lexeme/value>, line: <1-based>, col: <1-based> }.
 * Token types: id, num, str, op, punct, kw, ferr, eof. */
#ifndef LEXER_H
#define LEXER_H

#include "yv.h"

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

int isdigit(Yv *c);                  /* (c: str) -> bool */
int isupper(Yv *c);                  /* (c: str) -> bool */
int islower(Yv *c);                  /* (c: str) -> bool */
int isalpha(Yv *c);                  /* (c: str) -> bool */
int isalnum(Yv *c);                  /* (c: str) -> bool */
int is_radix_ch(Yv *c, long radix);  /* (c: str, radix: long) -> bool */
int isspace(Yv *c);                  /* (c: str) -> bool */
int ispunct(Yv *c);                  /* (c: str) -> bool */
Yv *lex_quoted(Yv *src, long i, long line, long col);
                                     /* -> { text: str, end: long, line: long, col: long } */
Yv *mktok(Yv *t, Yv *v, long line, long col);
                                     /* -> { t: str, v: str, line: long, col: long } */
long hexvalx(Yv *c);                 /* (c: str) -> long */
Yv *twocharop(Yv *src, long i);      /* (src: str, i: long) -> str */
int issingleop(Yv *c);               /* (c: str) -> bool */
Yv *slash(void);                     /* () -> str */
int isdigitch(Yv *c);                /* (c: str) -> bool */
Yv *tokenize(Yv *src);               /* (src: str) -> [{ t: str, v: str, line: long, col: long }] */
Yv *fstr_walk(Yv *src, long q);      /* (src: str, q: long) -> { end: long, err: str, at: long, fields: [long] } */

#endif /* LEXER_H */
