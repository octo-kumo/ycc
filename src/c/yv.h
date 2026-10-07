/* yv.h — the Y value model, the one shared runtime of the C copy.
 *
 * The C compiler (src/c) is a 1:1 copy of the Y compiler (src/y); this
 * header provides the DATA semantics the Y code runs on:
 *
 *   none | bool | long | float | str | array | record
 *
 * Arrays and records are REFERENCE values (shared by every binding; push()
 * grows in place and returns the same array — the Y rules). Strings and
 * numbers are immutable values. Values are allocated once and kept for
 * the process lifetime (the compiler is a batch tool; freeing is not
 * needed and would fight the sharing semantics).
 *
 * Scalar mapping (PORTING.md): long -> long, float -> double, bool -> int,
 * str/record/array/option -> Yv *. Boxing at the boundaries: yv_long/yv_l,
 * yv_bool/yv_b, yv_float/yv_f.
 */
#ifndef YV_H
#define YV_H

#include "ylong.h"
#include <stddef.h>

typedef enum { Y_NONE, Y_BOOL, Y_LONG, Y_FLOAT, Y_STR, Y_ARR, Y_REC } YTag;

typedef struct Yv Yv;

struct Yv {
    YTag tag;
    union {
        int b;
        ylong l;
        double f;
        struct {
            char *p;   /* NUL-terminated bytes (convenience) */
            size_t n;  /* byte length */
        } s;
        struct {
            Yv **items;
            size_t len, cap;
        } a;
        struct {
            char **keys; /* NUL-terminated */
            Yv **vals;
            size_t len, cap;
        } r;
    } u;
};

/* ── constructors ────────────────────────────────────────────────────── */
Yv *yv_none(void);
Yv *yv_bool(int v);
Yv *yv_long(ylong v);
Yv *yv_float(double v);
/* Strings are byte strings with a length (a Y `str` may contain NUL).
 * For LITERALS `ys("...")` is a macro that keeps every byte, embedded NUL
 * included; ys_cstr() is for NUL-terminated dynamic text. A literal's value
 * is made once where it is written and shared by every evaluation (values
 * are immutable: nothing writes into one after its constructor). */
/* `ys("literal")` -- a str from a string LITERAL, made once per call site.
 * It is a MACRO and its argument must be a literal: the length is
 * sizeof(lit) - 1, so an EXPRESSION argument sizes the pointer instead (8)
 * and truncates to seven bytes of whatever it points at. `ys(last ? "long"
 * : "short")` is that mistake; write one ys() per literal, or ys_cstr(expr)
 * for a NUL-terminated string that is not a literal. (Found by the port
 * gate: ycc passed LONG_MAX where cycc passed 0, and the compiler cycc built
 * could not resolve its own imports.) */
#define ys(lit) (__extension__({ static Yv *ys_lit_; \
    ys_lit_ ? ys_lit_ : (ys_lit_ = ys_n((lit), sizeof(lit) - 1)); }))
Yv *ys_cstr(const char *s);           /* string from NUL-terminated text */
Yv *ys_n(const char *p, size_t n);    /* string from raw bytes */
Yv *ys_fmt(const char *fmt, ...);     /* formatted string (printf-style) */

/* The twin of a Y top-level `embed NAME from "path";` (native.y embeds the
 * std sources it splices into programs): the file's bytes are linked in
 * when cycc is BUILT, by the assembler's .incbin. The path is relative to
 * the directory gcc runs in, the repo root (where the Makefile runs it).
 * NAME() returns the bytes as a str; the Y twin's NAME is a str const.
 *
 * `.pushsection`/`.popsection` are ELF directives; a COFF assembler (mingw's)
 * wants an explicit `.section`, and the section's name is `.rdata` there where
 * ELF says `.rodata`. The switch keeps one macro and one instruction. */
#ifdef _WIN32
#define Y_EMBED(name, path)                                             \
    __asm__(".section .rdata,\"dr\"\n"                                  \
            "y_embed_" #name ":\n"                                      \
            ".incbin \"" path "\"\n"                                    \
            "y_embed_" #name "_end:\n"                                  \
            ".text\n");                                                 \
    extern const char y_embed_##name[], y_embed_##name##_end[];         \
    static Yv *name(void) {                                             \
        return ys_n(y_embed_##name,                                     \
                    (size_t)(y_embed_##name##_end - y_embed_##name));   \
    }
#else
#define Y_EMBED(name, path)                                             \
    __asm__(".pushsection .rodata\n"                                    \
            "y_embed_" #name ":\n"                                      \
            ".incbin \"" path "\"\n"                                    \
            "y_embed_" #name "_end:\n"                                  \
            ".popsection\n");                                           \
    extern const char y_embed_##name[], y_embed_##name##_end[];         \
    static Yv *name(void) {                                             \
        return ys_n(y_embed_##name,                                     \
                    (size_t)(y_embed_##name##_end - y_embed_##name));   \
    }
#endif

/* boxed scalar accessors (unchecked; used at typed boundaries) */
ylong yv_l(const Yv *v);
int yv_b(const Yv *v);
double yv_f(const Yv *v);

/* ── values ──────────────────────────────────────────────────────────── */
int yv_truth(const Yv *v);            /* the value in an `if`/`while` */
int yv_eq(const Yv *a, const Yv *b);  /* value equality (str by content) */
int yv_is_none(const Yv *v);          /* `x == none` */
Yv *yv_unwrap(const Yv *v);           /* unwrap(v): trap on none */
ylong yv_len(const Yv *v);             /* str chars / array count / record fields */

/* ── strings ─────────────────────────────────────────────────────────── */
Yv *ys_cat(const Yv *a, const Yv *b);
Yv *ys_slice(const Yv *s, ylong lo, ylong hi);       /* s[lo:hi], clamped */
Yv *ys_slice_from(const Yv *s, ylong lo);           /* s[lo:] */
int ys_eq(const Yv *a, const Yv *b);
int ys_eq_lit(const Yv *a, const char *lit);
int ys_cmp(const Yv *a, const Yv *b); /* strcmp sign: <str lexicographic> */
Yv *ys_trim(const Yv *s);
Yv *ys_join(const Yv *arr, const Yv *sep);   /* [str] join */
Yv *ys_split(const Yv *s, const Yv *sep);    /* -> [str] */
ylong ys_index_of(const Yv *s, const Yv *sub);
ylong ys_last_index_of(const Yv *s, const Yv *sub);
/* std/str.y's y_str_at / y_str_starts_with, as the C twin uses them:
 * `p` occurs in `s` at byte offset `at` (false past the end of s). */
int ys_at(const Yv *s, const Yv *p, ylong at);
int ys_starts_with(const Yv *s, const Yv *p);
int ys_ends_with(const Yv *s, const Yv *p);
ylong ys_ord(const Yv *s);             /* first byte */
ylong ys_byte_at(const Yv *s, ylong i); /* byte i (0..255); traps out of bounds */
ylong ys_byte_peek(const Yv *s, ylong i); /* byte i, or -1 past either end:
                                           the clamped read s[i:i + 1] gives
                                           in Y (an empty slice), for the
                                           places that peek at what may be
                                           the byte after the last */
Yv *ys_chr(ylong v);
Yv *ys_tostring(const Yv *v);         /* the format the native tostring prints */
Yv *ys_long(ylong v);                  /* tostring of a long */
ylong ys_tolong(const Yv *s);          /* string -> long (0 on garbage) */
Yv *ys_tolong_opt(const Yv *s);        /* `tolong(s)`: some(n) or none */

/* ── arrays (reference values) ───────────────────────────────────────── */
/* [v0, v1, ...] from n values (no sentinel). n is the count, and the values
 * that follow are just arguments: yav stores exactly n of them and DROPS THE
 * REST with no diagnostic. So a value added here without bumping n produces an
 * array shorter than its author believed, and the name that goes missing is
 * whichever happened to be last -- which is how an f-string's #fmt once
 * vanished from native.c's INTRINSICS and every f-string in the corpus broke.
 *
 * The C twin states n by hand where Y counts itself, so for a list of values
 * use yavs, which ends in a sentinel and has no count to get wrong:
 *
 *     INTRINSICS = yavs(ys("print"), ys("len"), ..., NULL);
 *
 * There is no limit on how many values, because nothing is counted.
 */
Yv *yav(size_t n, ...);
Yv *yavs(Yv *first, ...);             /* NULL-terminated; no count to state */
Yv *ya_rep(Yv *v, ylong n);            /* [v; n] */
Yv *ya_get(const Yv *a, ylong i);      /* bounds-checked (exit on OOB) */
void ya_set(Yv *a, ylong i, Yv *v);    /* bounds-checked */
Yv *ya_push(Yv *a, Yv *v);            /* in place, returns a (the Y rule) */
Yv *ya_slice(const Yv *a, ylong lo, ylong hi); /* new [T]; clamped */

/* ── records (reference values, insertion-ordered) ───────────────────── */
Yv *yr(size_t n, ...);                /* n (key, value) pairs (no sentinel) */
Yv *yr_new(void);
Yv *yr_get(const Yv *m, const char *key); /* missing -> yv_none() */
Yv *yr_set(Yv *m, const char *key, Yv *v); /* insert or update in place */
int yr_has(const Yv *m, const char *key);

/* ── builtins ──────────────────────────────────────────────────────────
 * What the C modules call, plus the rest of the value model's interface:
 * a few of these (ya_slice, ya_rep, yr_has, yv_eq, from_bytes, byte_len,
 * the float boxing) are the PORTING.md spellings of Y builtins the C copy
 * does not currently reach. */
void puts_(const Yv *s);              /* puts(s) */
void eputs_(const Yv *s);             /* eputs(s) */
void exit_(ylong code);                /* exit(code) */
Yv *read_file(const Yv *path);        /* str contents, or none (str?) */
int write_file(const Yv *path, const Yv *data);
int write_bytes(const Yv *path, const Yv *bytearr, ylong mode);
int remove_file(const Yv *path);        /* remove_file(path): unlink(2) */
void yv_set_argv(int argc, char **argv); /* the driver feeds argv() */
Yv *argv_(void);                      /* [str] program arguments */
ylong clock_us(void);
ylong heap_used(void);
Yv *bytes_of(const Yv *s);            /* bytes(s): str -> [byte] */
Yv *from_bytes(const Yv *a);          /* from_bytes(b): [byte] -> str */
ylong byte_len(const Yv *s);           /* byte_len(s) */

#endif /* YV_H */
