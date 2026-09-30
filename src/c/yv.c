/* yv.c — the Y value model (see yv.h / PORTING.md).
 *
 * The behavior here mirrors the old C runtime exactly (it is the behavior
 * the reference ycc binary was built under): substr clamps like C,
 * tostring formats like the VM's val_to_str, push grows in place with
 * 0->8->doubling capacity, arrays and maps are shared references.
 */
#include "yv.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static long g_heap_used = 0;

static void *yalloc(size_t n) {
    void *p = malloc(n);
    if (!p) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    g_heap_used += (long)n;
    return p;
}

static char *ystrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = yalloc(n);
    memcpy(p, s, n);
    return p;
}

static char *ystrndup(const char *s, size_t n) {
    char *p = yalloc(n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static Yv *ynew(YTag tag) {
    Yv *v = yalloc(sizeof(Yv));
    v->tag = tag;
    return v;
}

/* ── constructors ────────────────────────────────────────────────────── */

Yv *yv_null(void) {
    Yv *v = ynew(Y_NULL);
    v->u.l = 0;
    return v;
}

Yv *yv_bool(int b) {
    Yv *v = ynew(Y_BOOL);
    v->u.b = b ? 1 : 0;
    return v;
}

Yv *yv_long(long l) {
    Yv *v = ynew(Y_LONG);
    v->u.l = l;
    return v;
}

Yv *yv_float(double f) {
    Yv *v = ynew(Y_FLOAT);
    v->u.f = f;
    return v;
}

Yv *ys_cstr(const char *s) {
    Yv *v = ynew(Y_STR);
    v->u.s.p = ystrdup(s ? s : "");
    v->u.s.n = strlen(v->u.s.p);
    return v;
}

Yv *ys_n(const char *p, size_t n) {
    Yv *v = ynew(Y_STR);
    v->u.s.p = ystrndup(p, n);
    v->u.s.n = n;
    return v;
}

Yv *ys_fmt(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    return ys_cstr(buf);
}

long yv_l(const Yv *v) { return v && v->tag == Y_LONG ? v->u.l : 0; }
int yv_b(const Yv *v) { return v && v->tag == Y_BOOL ? v->u.b : 0; }
double yv_f(const Yv *v) {
    if (!v) return 0.0;
    if (v->tag == Y_FLOAT) return v->u.f;
    if (v->tag == Y_LONG) return (double)v->u.l;
    return 0.0;
}

/* ── values ──────────────────────────────────────────────────────────── */

int yv_truth(const Yv *v) {
    if (!v) return 0;
    switch (v->tag) {
    case Y_BOOL: return v->u.b;
    case Y_LONG: return v->u.l != 0;
    case Y_FLOAT: return v->u.f != 0.0;
    case Y_NULL: return 0;
    default: return 1;
    }
}

int yv_is_null(const Yv *v) { return !v || v->tag == Y_NULL; }

Yv *yv_unwrap(const Yv *v) {
    if (!v || v->tag == Y_NULL) {
        fprintf(stderr, "runtime error: unwrap of null\n");
        exit(1);
    }
    return (Yv *)v;
}

long yv_len(const Yv *v) {
    if (!v) return 0;
    switch (v->tag) {
    case Y_STR: return (long)v->u.s.n;
    case Y_ARR: return (long)v->u.a.len;
    case Y_MAP: return (long)v->u.m.len;
    default: return 0;
    }
}

/* ── strings ─────────────────────────────────────────────────────────── */

Yv *ys_cat(const Yv *a, const Yv *b) {
    /* length-based: a Y str may contain NUL bytes */
    size_t an = (a && a->tag == Y_STR) ? a->u.s.n : 0;
    size_t bn = (b && b->tag == Y_STR) ? b->u.s.n : 0;
    Yv *v = ynew(Y_STR);
    v->u.s.p = yalloc(an + bn + 1);
    if (an) memcpy(v->u.s.p, a->u.s.p, an);
    if (bn) memcpy(v->u.s.p + an, b->u.s.p, bn);
    v->u.s.p[an + bn] = '\0';
    v->u.s.n = an + bn;
    return v;
}

Yv *ys_substr(const Yv *s, long start, long count) {
    if (!s || s->tag != Y_STR) { return ys(""); }
    long slen = (long)s->u.s.n;
    long st = start;
    long cnt = count;
    if (st < 0) st = 0;
    if (st >= slen) { return ys(""); }
    if (cnt < 0 || st + cnt > slen) cnt = slen - st;
    return ys_n(s->u.s.p + st, (size_t)cnt);
}

int ys_eq(const Yv *a, const Yv *b) {
    size_t an = (a && a->tag == Y_STR) ? a->u.s.n : 0;
    size_t bn = (b && b->tag == Y_STR) ? b->u.s.n : 0;
    if (an != bn) return 0;
    return an == 0 || memcmp(a->u.s.p, b->u.s.p, an) == 0;
}

int ys_eq_lit(const Yv *a, const char *lit) {
    if (!a || a->tag != Y_STR) return 0;
    size_t n = strlen(lit);
    return a->u.s.n == n && memcmp(a->u.s.p, lit, n) == 0;
}

int ys_cmp(const Yv *a, const Yv *b) {
    /* length-aware strcmp: common prefix first, then the lengths */
    size_t an = (a && a->tag == Y_STR) ? a->u.s.n : 0;
    size_t bn = (b && b->tag == Y_STR) ? b->u.s.n : 0;
    size_t n = an < bn ? an : bn;
    int c = n ? memcmp(a->u.s.p, b->u.s.p, n) : 0;
    if (c) return c;
    return an < bn ? -1 : (an > bn ? 1 : 0);
}

Yv *ys_trim(const Yv *x) {
    if (!x || x->tag != Y_STR) { return ys(""); }
    const char *s = x->u.s.p;
    size_t slen = x->u.s.n;
    while (slen > 0 && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) {
        s++;
        slen--;
    }
    while (slen > 0 && (s[slen - 1] == ' ' || s[slen - 1] == '\t' ||
                        s[slen - 1] == '\n' || s[slen - 1] == '\r'))
        slen--;
    return ys_n(s, slen);
}

Yv *ys_join(const Yv *arr, const Yv *sep) {
    if (!arr || arr->tag != Y_ARR || !sep || sep->tag != Y_STR) { return ys(""); }
    size_t total = 1;
    for (size_t i = 0; i < arr->u.a.len; i++) {
        Yv *e = ys_tostring(arr->u.a.items[i]);
        total += e->u.s.n + sep->u.s.n;
    }
    char *buf = yalloc(total + 1);
    size_t pos = 0;
    for (size_t i = 0; i < arr->u.a.len; i++) {
        if (i > 0) {
            memcpy(buf + pos, sep->u.s.p, sep->u.s.n);
            pos += sep->u.s.n;
        }
        Yv *e = ys_tostring(arr->u.a.items[i]);
        memcpy(buf + pos, e->u.s.p, e->u.s.n);
        pos += e->u.s.n;
    }
    buf[pos] = '\0';
    return ys_n(buf, pos);
}

/* first index of sub at or after `from` in s[0..n), or (size_t)-1 */
static size_t ymem_find(const char *s, size_t n, const char *sub, size_t m,
                        size_t from) {
    if (m == 0) return from <= n ? from : (size_t)-1;
    if (m > n) return (size_t)-1;
    for (size_t i = from; i + m <= n; i++) {
        if (memcmp(s + i, sub, m) == 0) return i;
    }
    return (size_t)-1;
}

Yv *ys_split(const Yv *s, const Yv *delim) {
    Yv *out = ynew(Y_ARR);
    out->u.a.items = NULL;
    out->u.a.len = 0;
    out->u.a.cap = 0;
    if (!s || s->tag != Y_STR || !delim || delim->tag != Y_STR) { return out; }
    const char *str = s->u.s.p;
    size_t n = s->u.s.n;
    const char *d = delim->u.s.p;
    size_t dlen = delim->u.s.n;
    if (dlen == 0) { return out; }
    size_t count = 0;
    size_t p = 0;
    while (p < n) {
        count++;
        size_t nx = ymem_find(str, n, d, dlen, p);
        p = nx != (size_t)-1 ? nx + dlen : n;
    }
    out->u.a.items = yalloc(sizeof(Yv *) * (count > 0 ? count : 1));
    out->u.a.cap = count;
    size_t i = 0;
    p = 0;
    while (p < n) {
        size_t nx = ymem_find(str, n, d, dlen, p);
        size_t len = nx != (size_t)-1 ? nx - p : n - p;
        out->u.a.items[i++] = ys_n(str + p, len);
        p = nx != (size_t)-1 ? nx + dlen : n;
    }
    out->u.a.len = i;
    return out;
}

long ys_index_of(const Yv *s, const Yv *sub) {
    if (!s || s->tag != Y_STR || !sub || sub->tag != Y_STR) { return -1; }
    size_t i = ymem_find(s->u.s.p, s->u.s.n, sub->u.s.p, sub->u.s.n, 0);
    return i == (size_t)-1 ? -1 : (long)i;
}

long ys_last_index_of(const Yv *s, const Yv *sub) {
    if (!s || s->tag != Y_STR || !sub || sub->tag != Y_STR) { return -1; }
    size_t n = s->u.s.n, m = sub->u.s.n;
    if (m == 0) { return (long)n; }
    for (long i = (long)(n - m); i >= 0; i--) {
        if (memcmp(s->u.s.p + i, sub->u.s.p, m) == 0) { return i; }
    }
    return -1;
}

long ys_ord(const Yv *x) {
    if (!x || x->tag != Y_STR || x->u.s.n == 0) { return -1; }
    return (long)(unsigned char)x->u.s.p[0];
}

Yv *ys_chr(long v) {
    char buf[2];
    buf[0] = (char)(v & 0xFF);
    buf[1] = '\0';
    return ys_n(buf, 1);
}

Yv *ys_long(long v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%ld", v);
    return ys_cstr(buf);
}

long ys_tonum(const Yv *x) {
    if (!x) return 0;
    if (x->tag == Y_LONG) return x->u.l;
    if (x->tag == Y_FLOAT) return (long)x->u.f;
    if (x->tag != Y_STR) return 0;
    char *end;
    long v = strtol(x->u.s.p, &end, 10);
    if (end == x->u.s.p) return 0;
    return v;
}

static char *escape_str(const char *s) {
    if (!s) return ystrdup("NULL");
    size_t len = 0;
    for (size_t i = 0; s[i]; i++) {
        char c = s[i];
        if (c == '\n' || c == '\t' || c == '\r' || c == '\\' || c == '\"') len += 2;
        else if ((unsigned char)c < 32 || (unsigned char)c > 126) len += 4;
        else len += 1;
    }
    char *esc = yalloc(len + 1);
    size_t pos = 0;
    for (size_t i = 0; s[i]; i++) {
        char c = s[i];
        if (c == '\n') { esc[pos++] = '\\'; esc[pos++] = 'n'; }
        else if (c == '\t') { esc[pos++] = '\\'; esc[pos++] = 't'; }
        else if (c == '\r') { esc[pos++] = '\\'; esc[pos++] = 'r'; }
        else if (c == '\\') { esc[pos++] = '\\'; esc[pos++] = '\\'; }
        else if (c == '\"') { esc[pos++] = '\\'; esc[pos++] = '\"'; }
        else if ((unsigned char)c < 32 || (unsigned char)c > 126) {
            snprintf(esc + pos, 5, "\\x%02x", (unsigned char)c);
            pos += 4;
        } else { esc[pos++] = c; }
    }
    esc[pos] = '\0';
    return esc;
}

Yv *ys_tostring(const Yv *v) {
    char buf[8192];
    buf[0] = '\0';
    size_t cap = sizeof(buf);
    if (!v) { return ys("null"); }
    switch (v->tag) {
    case Y_NULL: return ys("null");
    case Y_BOOL: return ys_cstr(v->u.b ? "true" : "false");
    case Y_LONG: return ys_long(v->u.l);
    case Y_FLOAT: {
        snprintf(buf, cap, "%f", v->u.f);
        return ys_cstr(buf);
    }
    case Y_STR: return ys_n(v->u.s.p, v->u.s.n);
    case Y_ARR: {
        /* "[e0, e1, ...]" — the VM's val_to_str format */
        size_t total = 2;
        for (size_t i = 0; i < v->u.a.len; i++) {
            Yv *e = ys_tostring(v->u.a.items[i]);
            total += strlen(e->u.s.p) + 2;
        }
        char *b = yalloc(total + 1);
        size_t pos = 0;
        b[pos++] = '[';
        for (size_t i = 0; i < v->u.a.len; i++) {
            if (i > 0) { b[pos++] = ','; b[pos++] = ' '; }
            Yv *e = ys_tostring(v->u.a.items[i]);
            size_t el = strlen(e->u.s.p);
            memcpy(b + pos, e->u.s.p, el);
            pos += el;
        }
        b[pos++] = ']';
        b[pos] = '\0';
        return ys_n(b, pos);
    }
    case Y_MAP: {
        size_t total = 3;
        for (size_t i = 0; i < v->u.m.len; i++) {
            char *k = escape_str(v->u.m.keys[i]);
            Yv *e = ys_tostring(v->u.m.vals[i]);
            total += strlen(k) + strlen(e->u.s.p) + 4;
        }
        char *b = yalloc(total + 1);
        size_t pos = 0;
        b[pos++] = '{';
        for (size_t i = 0; i < v->u.m.len; i++) {
            if (i > 0) { b[pos++] = ','; b[pos++] = ' '; }
            char *k = escape_str(v->u.m.keys[i]);
            size_t kl = strlen(k);
            memcpy(b + pos, k, kl);
            pos += kl;
            b[pos++] = ':';
            b[pos++] = ' ';
            Yv *e = ys_tostring(v->u.m.vals[i]);
            size_t el = strlen(e->u.s.p);
            memcpy(b + pos, e->u.s.p, el);
            pos += el;
        }
        b[pos++] = '}';
        b[pos] = '\0';
        return ys_n(b, pos);
    }
    }
    return ys("null");
}

/* ── arrays (reference values) ───────────────────────────────────────── */

static void ya_grow(Yv *a, size_t need) {
    if (need <= a->u.a.cap) return;
    size_t cap = a->u.a.cap < 8 ? 8 : a->u.a.cap * 2;
    while (cap < need) cap *= 2;
    Yv **items = yalloc(sizeof(Yv *) * cap);
    if (a->u.a.len) memcpy(items, a->u.a.items, sizeof(Yv *) * a->u.a.len);
    a->u.a.items = items;
    a->u.a.cap = cap;
}

Yv *yav(size_t n, ...) {
    Yv *v = ynew(Y_ARR);
    v->u.a.items = NULL;
    v->u.a.len = 0;
    v->u.a.cap = 0;
    if (n) {
        ya_grow(v, n);
        va_list ap;
        va_start(ap, n);
        for (size_t i = 0; i < n; i++) v->u.a.items[i] = va_arg(ap, Yv *);
        va_end(ap);
        v->u.a.len = n;
    }
    return v;
}

Yv *ya_rep(Yv *x, long n) {
    Yv *v = ynew(Y_ARR);
    v->u.a.items = NULL;
    v->u.a.len = 0;
    v->u.a.cap = 0;
    if (n > 0) {
        ya_grow(v, (size_t)n);
        for (long i = 0; i < n; i++) v->u.a.items[i] = x;
        v->u.a.len = (size_t)n;
    }
    return v;
}

Yv *ya_get(const Yv *a, long i) {
    if (!a || a->tag != Y_ARR || i < 0 || (size_t)i >= a->u.a.len) {
        fprintf(stderr, "runtime error: index out of bounds\n");
        exit(1);
    }
    return a->u.a.items[i];
}

void ya_set(Yv *a, long i, Yv *v) {
    if (!a || a->tag != Y_ARR || i < 0 || (size_t)i >= a->u.a.len) {
        fprintf(stderr, "runtime error: index out of bounds\n");
        exit(1);
    }
    a->u.a.items[i] = v;
}

Yv *ya_push(Yv *a, Yv *v) {
    if (!a || a->tag != Y_ARR) {
        a = ynew(Y_ARR);
        a->u.a.items = NULL;
        a->u.a.len = 0;
        a->u.a.cap = 0;
    }
    ya_grow(a, a->u.a.len + 1);
    a->u.a.items[a->u.a.len++] = v;
    return a;
}

Yv *ya_slice(const Yv *a, long lo, long hi) {
    Yv *v = ynew(Y_ARR);
    v->u.a.items = NULL;
    v->u.a.len = 0;
    v->u.a.cap = 0;
    if (!a || a->tag != Y_ARR) return v;
    long n = (long)a->u.a.len;
    if (lo < 0) lo = 0;
    if (lo > n) lo = n;
    if (hi < 0 || hi > n) hi = n;
    if (hi < lo) hi = lo;
    long cnt = hi - lo;
    if (cnt > 0) {
        ya_grow(v, (size_t)cnt);
        for (long i = 0; i < cnt; i++) v->u.a.items[i] = a->u.a.items[lo + i];
        v->u.a.len = (size_t)cnt;
    }
    return v;
}

/* ── maps / records ──────────────────────────────────────────────────── */

static void ym_grow(Yv *m, size_t need) {
    if (need <= m->u.m.cap) return;
    size_t cap = m->u.m.cap < 8 ? 8 : m->u.m.cap * 2;
    while (cap < need) cap *= 2;
    char **keys = yalloc(sizeof(char *) * cap);
    Yv **vals = yalloc(sizeof(Yv *) * cap);
    if (m->u.m.len) {
        memcpy(keys, m->u.m.keys, sizeof(char *) * m->u.m.len);
        memcpy(vals, m->u.m.vals, sizeof(Yv *) * m->u.m.len);
    }
    m->u.m.keys = keys;
    m->u.m.vals = vals;
    m->u.m.cap = cap;
}

Yv *ym_new(void) {
    Yv *v = ynew(Y_MAP);
    v->u.m.keys = NULL;
    v->u.m.vals = NULL;
    v->u.m.len = 0;
    v->u.m.cap = 0;
    return v;
}

Yv *ym(size_t n, ...) {
    Yv *v = ym_new();
    va_list ap;
    va_start(ap, n);
    for (size_t i = 0; i < n; i++) {
        const char *k = va_arg(ap, const char *);
        Yv *val = va_arg(ap, Yv *);
        ym_set(v, k, val);
    }
    va_end(ap);
    return v;
}

Yv *ym_get(const Yv *m, const char *key) {
    if (m && m->tag == Y_MAP) {
        for (size_t i = 0; i < m->u.m.len; i++) {
            if (strcmp(m->u.m.keys[i], key) == 0) return m->u.m.vals[i];
        }
    }
    return yv_null();
}

Yv *ym_set(Yv *m, const char *key, Yv *v) {
    if (!m || m->tag != Y_MAP) return m;
    for (size_t i = 0; i < m->u.m.len; i++) {
        if (strcmp(m->u.m.keys[i], key) == 0) {
            m->u.m.vals[i] = v;
            return m;
        }
    }
    ym_grow(m, m->u.m.len + 1);
    m->u.m.keys[m->u.m.len] = ystrdup(key);
    m->u.m.vals[m->u.m.len] = v;
    m->u.m.len++;
    return m;
}

int ym_has(const Yv *m, const char *key) {
    if (!m || m->tag != Y_MAP) return 0;
    for (size_t i = 0; i < m->u.m.len; i++) {
        if (strcmp(m->u.m.keys[i], key) == 0) return 1;
    }
    return 0;
}

int yv_eq(const Yv *a, const Yv *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->tag != b->tag) return 0;
    switch (a->tag) {
    case Y_NULL: return 1;
    case Y_BOOL: return a->u.b == b->u.b;
    case Y_LONG: return a->u.l == b->u.l;
    case Y_FLOAT: return a->u.f == b->u.f;
    case Y_STR: return strcmp(a->u.s.p, b->u.s.p) == 0;
    case Y_ARR: {
        if (a->u.a.len != b->u.a.len) return 0;
        for (size_t i = 0; i < a->u.a.len; i++)
            if (!yv_eq(a->u.a.items[i], b->u.a.items[i])) return 0;
        return 1;
    }
    case Y_MAP: {
        if (a->u.m.len != b->u.m.len) return 0;
        for (size_t i = 0; i < a->u.m.len; i++) {
            if (strcmp(a->u.m.keys[i], b->u.m.keys[i]) != 0) return 0;
            if (!yv_eq(a->u.m.vals[i], b->u.m.vals[i])) return 0;
        }
        return 1;
    }
    }
    return 0;
}

/* ── builtins ────────────────────────────────────────────────────────── */

void puts_(const Yv *s) {
    if (s && s->tag == Y_STR) fputs(s->u.s.p, stdout);
    else fputs("null", stdout);
    fflush(stdout);
}

void eputs_(const Yv *s) {
    if (s && s->tag == Y_STR) fputs(s->u.s.p, stderr);
    else fputs("null", stderr);
    fflush(stderr);
}

void exit_(long code) { exit((int)code); }

Yv *read_file(const Yv *path) {
    if (!path || path->tag != Y_STR) return yv_null();
    FILE *f = fopen(path->u.s.p, "rb");
    if (!f) return yv_null();
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return yv_null(); }
    char *buf = yalloc((size_t)sz + 1);
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    return ys_n(buf, rd);
}

int write_file(const Yv *path, const Yv *content) {
    if (!path || path->tag != Y_STR || !content || content->tag != Y_STR) return 0;
    FILE *f = fopen(path->u.s.p, "wb");
    if (!f) return 0;
    size_t n = strlen(content->u.s.p);
    size_t wr = fwrite(content->u.s.p, 1, n, f);
    fclose(f);
    return wr == n;
}

int write_bytes(const Yv *path, const Yv *bytearr, long mode) {
    if (!path || path->tag != Y_STR || !bytearr || bytearr->tag != Y_ARR) return 0;
    size_t n = bytearr->u.a.len;
    char *buf = yalloc(n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        Yv *e = bytearr->u.a.items[i];
        buf[i] = (char)(e && e->tag == Y_LONG ? (e->u.l & 0xFF) : 0);
    }
    FILE *f = fopen(path->u.s.p, "wb");
    if (!f) return 0;
    size_t wr = fwrite(buf, 1, n, f);
    fclose(f);
    if (wr != n) return 0;
    if (mode >= 0) {
        if (chmod(path->u.s.p, (mode_t)mode) != 0) return 0;
    }
    return 1;
}

static Yv *g_argv = NULL;

void yv_set_argv(int argc, char **argv) {
    Yv *a = ynew(Y_ARR);
    a->u.a.items = NULL;
    a->u.a.len = 0;
    a->u.a.cap = 0;
    for (int i = 0; i < argc; i++) ya_push(a, ys_cstr(argv[i]));
    g_argv = a;
}

Yv *argv_(void) { return g_argv ? g_argv : yav(0); }

long clock_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000000L + ts.tv_nsec / 1000;
}

long heap_used(void) { return g_heap_used; }

Yv *bytes_of(const Yv *s) {
    Yv *v = ynew(Y_ARR);
    v->u.a.items = NULL;
    v->u.a.len = 0;
    v->u.a.cap = 0;
    size_t n = (s && s->tag == Y_STR) ? s->u.s.n : 0;
    if (n) {
        ya_grow(v, n);
        for (size_t i = 0; i < n; i++)
            v->u.a.items[i] = yv_long((long)(unsigned char)s->u.s.p[i]);
        v->u.a.len = n;
    }
    return v;
}

Yv *from_bytes(const Yv *a) {
    if (!a || a->tag != Y_ARR) { return ys(""); }
    size_t n = a->u.a.len;
    char *buf = yalloc(n + 1);
    for (size_t i = 0; i < n; i++) {
        Yv *e = a->u.a.items[i];
        buf[i] = (char)(e && e->tag == Y_LONG ? (e->u.l & 0xFF) : 0);
    }
    buf[n] = '\0';
    return ys_n(buf, n);
}

long byte_len(const Yv *s) {
    return (s && s->tag == Y_STR) ? (long)s->u.s.n : 0;
}
