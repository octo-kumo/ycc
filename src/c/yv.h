/* Shared, boxed values for the generated C bootstrap. Arrays and records alias. */
#ifndef YV_H
#define YV_H

#include "ylong.h"
#include <stddef.h>
#include <stdint.h>

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
            size_t bytewise; /* 1: boxed bytes, 2: packed bytes; retained through slices */
        } a;
        struct {
            char **keys; /* NUL-terminated */
            Yv **vals;
            size_t len, cap;
        } r;
    } u;
};

/* Small integers are immediate values, never heap addresses. Large integers
 * (including pointers held by the hosted closure ABI) remain scanned boxes. */
#define YV_IMMEDIATE_LIMIT ((ylong)2097152)
static inline int yv_fits_immediate(ylong n) {
    return (uint64_t)n + (uint64_t)YV_IMMEDIATE_LIMIT < (uint64_t)YV_IMMEDIATE_LIMIT * 2;
}
static inline int yv_is_immediate(const Yv *v) { return (uintptr_t)v & 1; }
static inline Yv *yv_immediate(ylong n) { return (Yv *)(((uintptr_t)n << 1) | 1); }
static inline YTag yv_tag(const Yv *v) {
    return yv_is_immediate(v) ? Y_LONG : v ? v->tag : Y_NONE;
}
static inline ylong yv_long_value(const Yv *v) {
    return yv_is_immediate(v) ? (ylong)(intptr_t)v >> 1 : v && v->tag == Y_LONG ? v->u.l : 0;
}

Yv *yv_none(void);
Yv *yv_bool(int v);
Yv *yv_long(ylong v);
Yv *yv_float(double v);
/* Literal-only constructor: sizeof preserves embedded NULs. */
#define ys(lit) (__extension__({ static Yv *ys_lit_; \
    ys_lit_ ? ys_lit_ : (ys_lit_ = ys_n((lit), sizeof(lit) - 1)); }))
Yv *ys_cstr(const char *s);           /* string from NUL-terminated text */
Yv *ys_n(const char *p, size_t n);    /* string from raw bytes */

/* boxed scalar accessors (unchecked; used at typed boundaries) */
ylong yv_l(const Yv *v);
double yv_f(const Yv *v);

int yv_truth(const Yv *v);            /* the value in an `if`/`while` */
int yv_eq(const Yv *a, const Yv *b);  /* value equality (str by content) */
int yv_is_none(const Yv *v);          /* `x == none` */
Yv *yv_unwrap(const Yv *v);           /* unwrap(v): trap on none */
ylong yv_len(const Yv *v);             /* str chars / array count / record fields */

Yv *ys_cat(const Yv *a, const Yv *b);
Yv *ys_slice(const Yv *s, ylong lo, ylong hi);       /* s[lo:hi], clamped */
int ys_cmp(const Yv *a, const Yv *b); /* strcmp sign: <str lexicographic> */
Yv *ys_trim(const Yv *s);
Yv *ys_join(const Yv *arr, const Yv *sep);   /* [str] join */
Yv *ys_split(const Yv *s, const Yv *sep);    /* -> [str] */
ylong ys_index_of(const Yv *s, const Yv *sub);
ylong ys_last_index_of(const Yv *s, const Yv *sub);
int ys_starts_with(const Yv *s, const Yv *p);
int ys_ends_with(const Yv *s, const Yv *p);
ylong ys_ord(const Yv *s);             /* first byte */
ylong ys_byte_at(const Yv *s, ylong i); /* byte i (0..255); traps out of bounds */
Yv *ys_chr(ylong v);
Yv *ys_tostring(const Yv *v);         /* the format the native tostring prints */
Yv *ys_tolong_opt(const Yv *s);        /* `tolong(s)`: some(n) or none */

Yv *yav(size_t n, ...);
Yv *ya_rep(Yv *v, ylong n);            /* [v; n] */
Yv *ya_bytes_zero(ylong n);           /* packed, zero-filled [byte] */
Yv *ya_get(const Yv *a, ylong i);      /* bounds-checked (exit on OOB) */
void ya_set(Yv *a, ylong i, Yv *v);    /* bounds-checked */
Yv *ya_push(Yv *a, Yv *v);            /* in place, returns a (the Y rule) */
Yv *ya_slice(const Yv *a, ylong lo, ylong hi); /* new [T]; clamped */

Yv *yr(size_t n, ...);                /* n (key, value) pairs (no sentinel) */
Yv *yr_get(const Yv *m, const char *key); /* missing -> yv_none() */
Yv *yr_set(Yv *m, const char *key, Yv *v); /* insert or update in place */
int yr_has(const Yv *m, const char *key);

/* Builtins used by generated programs. */
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
Yv *fs_getenv(const Yv *name);        /* fs.getenv: str value or none */
Yv *fs_make_dir(const Yv *p, ylong mode);
Yv *fs_make_dirs(const Yv *p);
Yv *fs_is_dir(const Yv *p);
Yv *fs_is_file(const Yv *p);
Yv *fs_remove_dir(const Yv *p);
Yv *fs_open_file(const Yv *p, const Yv *how);
Yv *fs_read_some(ylong fd, ylong cap);
Yv *fs_close_file(ylong fd);
Yv *fs_read_bytes(const Yv *p);
Yv *fs_list_dir(const Yv *p);
Yv *read_all_bytes(ylong fd);         /* every byte of fd -> [byte] */
int write_data(ylong fd, const Yv *a);  /* [byte] or str -> fd, all of it */
Yv *bytes_of(const Yv *s);            /* bytes(s): str -> [byte] */
Yv *from_bytes(const Yv *a);          /* from_bytes(b): [byte] -> str */
ylong byte_len(const Yv *s);           /* byte_len(s) */

#endif /* YV_H */
