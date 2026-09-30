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

#include <stddef.h>

typedef enum { Y_NONE, Y_BOOL, Y_LONG, Y_FLOAT, Y_STR, Y_ARR, Y_REC } YTag;

typedef struct Yv Yv;

struct Yv {
    YTag tag;
    union {
        int b;
        long l;
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
Yv *yv_long(long v);
Yv *yv_float(double v);
/* Strings are byte strings with a length (a Y `str` may contain NUL).
 * For LITERALS `ys("...")` is a macro that keeps every byte, embedded NUL
 * included; ys_cstr() is for NUL-terminated dynamic text. */
#define ys(lit) ys_n((lit), sizeof(lit) - 1)
Yv *ys_cstr(const char *s);           /* string from NUL-terminated text */
Yv *ys_n(const char *p, size_t n);    /* string from raw bytes */
Yv *ys_fmt(const char *fmt, ...);     /* formatted string (printf-style) */

/* boxed scalar accessors (unchecked; used at typed boundaries) */
long yv_l(const Yv *v);
int yv_b(const Yv *v);
double yv_f(const Yv *v);

/* ── values ──────────────────────────────────────────────────────────── */
int yv_truth(const Yv *v);            /* the value in an `if`/`while` */
int yv_eq(const Yv *a, const Yv *b);  /* value equality (str by content) */
int yv_is_none(const Yv *v);          /* `x == none` */
Yv *yv_unwrap(const Yv *v);           /* unwrap(v): trap on none */
long yv_len(const Yv *v);             /* str chars / array count / record fields */

/* ── strings ─────────────────────────────────────────────────────────── */
Yv *ys_cat(const Yv *a, const Yv *b);
Yv *ys_substr(const Yv *s, long start, long count); /* C-clamped semantics */
int ys_eq(const Yv *a, const Yv *b);
int ys_eq_lit(const Yv *a, const char *lit);
int ys_cmp(const Yv *a, const Yv *b); /* strcmp sign: <str lexicographic> */
Yv *ys_trim(const Yv *s);
Yv *ys_join(const Yv *arr, const Yv *sep);   /* [str] join */
Yv *ys_split(const Yv *s, const Yv *sep);    /* -> [str] */
long ys_index_of(const Yv *s, const Yv *sub);
long ys_last_index_of(const Yv *s, const Yv *sub);
long ys_ord(const Yv *s);             /* first byte */
Yv *ys_chr(long v);
Yv *ys_tostring(const Yv *v);         /* the format the native tostring prints */
Yv *ys_long(long v);                  /* tostring of a long */
long ys_tonum(const Yv *s);           /* string -> long (0 on garbage) */

/* ── arrays (reference values) ───────────────────────────────────────── */
Yv *yav(size_t n, ...);               /* [v0, v1, ...] from n values (no sentinel) */
Yv *ya_rep(Yv *v, long n);            /* [v; n] */
Yv *ya_get(const Yv *a, long i);      /* bounds-checked (exit on OOB) */
void ya_set(Yv *a, long i, Yv *v);    /* bounds-checked */
Yv *ya_push(Yv *a, Yv *v);            /* in place, returns a (the Y rule) */
Yv *ya_slice(const Yv *a, long lo, long hi); /* new [T]; clamped */

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
void exit_(long code);                /* exit(code) */
Yv *read_file(const Yv *path);        /* str contents, or none (str?) */
int write_file(const Yv *path, const Yv *data);
int write_bytes(const Yv *path, const Yv *bytearr, long mode);
void yv_set_argv(int argc, char **argv); /* the driver feeds argv() */
Yv *argv_(void);                      /* [str] program arguments */
long clock_us(void);
long heap_used(void);
Yv *bytes_of(const Yv *s);            /* bytes(s): str -> [byte] */
Yv *from_bytes(const Yv *a);          /* from_bytes(b): [byte] -> str */
long byte_len(const Yv *s);           /* byte_len(s) */

#endif /* YV_H */
