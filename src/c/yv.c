/* Boxed values for the generated C bootstrap. */
#include "ylong.h"
#include "yv.h"
#include "host.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static ylong g_heap_used = 0;

static void yoom(void) {
    fputs("runtime error: out of memory\n", stdout);
    fflush(stdout);
    exit(1);
}

/* GC and sanitizer builds allocate per object; other builds use aligned pools. */
#ifndef __has_feature
#define __has_feature(x) 0
#endif
#if defined(__SANITIZE_ADDRESS__) || __has_feature(address_sanitizer) || defined(YV_GC)
#define YV_POOL 0
#else
#define YV_POOL 1
#define YV_BLOCK ((size_t)32 << 20)
#define YV_BIG ((size_t)256 << 10)
static char *g_pool = NULL;
static size_t g_pool_left = 0;
#endif

static void *yalloc(size_t n) {
    g_heap_used += (ylong)n;
#if YV_POOL
    size_t r = (n + 7) & ~(size_t)7;
    if (r == 0) r = 8;
    if (r <= YV_BIG) {
        if (r > g_pool_left) {
            g_pool = malloc(YV_BLOCK);
            if (!g_pool) yoom();
            g_pool_left = YV_BLOCK;
        }
        void *p = g_pool;
        g_pool += r;
        g_pool_left -= r;
        return p;
    }
#endif
    void *p = malloc(n ? n : 1);
    if (!p) yoom();
    return p;
}

/* Raw bytes contain no pointers for the conservative collector to trace. */
static void *yalloc_bytes(size_t n) {
#ifdef YV_GC
    g_heap_used += (ylong)n;
    void *p = GC_malloc_atomic(n ? n : 1);
    if (!p) yoom();
    return p;
#else
    return yalloc(n);
#endif
}

static char *ystrdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = yalloc_bytes(n);
    memcpy(p, s, n);
    return p;
}

static char *ystrndup(const char *s, size_t n) {
    char *p = yalloc_bytes(n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static Yv *ynew(YTag tag) {
    Yv *v = yalloc(sizeof(Yv));
    v->tag = tag;
    return v;
}

static Yv *yarr_new(void) {
    Yv *v = ynew(Y_ARR);
    v->u.a.items = NULL;
    v->u.a.len = 0;
    v->u.a.cap = 0;
    v->u.a.bytewise = 0;
    return v;
}

/* Share immutable scalars. */
static Yv g_none = { .tag = Y_NONE, .u = { .l = 0 } };
static Yv g_true = { .tag = Y_BOOL, .u = { .b = 1 } };
static Yv g_false = { .tag = Y_BOOL, .u = { .b = 0 } };

Yv *yv_none(void) {
    return &g_none;
}

Yv *yv_bool(int b) {
    return b ? &g_true : &g_false;
}

Yv *yv_long(ylong l) {
    if (yv_fits_immediate(l)) return yv_immediate(l);
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

/* A str around buf (n bytes, NUL-terminated), which it takes as is. */
static Yv *ys_own(char *buf, size_t n) {
    Yv *v = ynew(Y_STR);
    v->u.s.p = buf;
    v->u.s.n = n;
    return v;
}

ylong yv_l(const Yv *v) { return yv_long_value(v); }
double yv_f(const Yv *v) {
    if (!v) return 0.0;
    if (yv_tag(v) == Y_FLOAT) return v->u.f;
    if (yv_tag(v) == Y_LONG) return (double)yv_l(v);
    return 0.0;
}

int yv_truth(const Yv *v) {
    if (!v) return 0;
    switch (yv_tag(v)) {
    case Y_BOOL: return v->u.b;
    case Y_LONG: return yv_l(v) != 0;
    case Y_FLOAT: return v->u.f != 0.0;
    case Y_NONE: return 0;
    default: return 1;
    }
}

int yv_is_none(const Yv *v) { return !v || yv_tag(v) == Y_NONE; }

Yv *yv_unwrap(const Yv *v) {
    if (!v || yv_tag(v) == Y_NONE) {
        fprintf(stderr, "runtime error: unwrap of none\n");
        exit(1);
    }
    return (Yv *)v;
}

ylong yv_len(const Yv *v) {
    if (!v) return 0;
    switch (yv_tag(v)) {
    case Y_STR: return (ylong)v->u.s.n;
    case Y_ARR: return (ylong)v->u.a.len;
    case Y_REC: return (ylong)v->u.r.len;
    default: return 0;
    }
}

Yv *ys_cat(const Yv *a, const Yv *b) {
    /* length-based: a Y str may contain NUL bytes */
    size_t an = (a && yv_tag(a) == Y_STR) ? a->u.s.n : 0;
    size_t bn = (b && yv_tag(b) == Y_STR) ? b->u.s.n : 0;
    Yv *v = ynew(Y_STR);
    v->u.s.p = yalloc_bytes(an + bn + 1);
    if (an) memcpy(v->u.s.p, a->u.s.p, an);
    if (bn) memcpy(v->u.s.p + an, b->u.s.p, bn);
    v->u.s.p[an + bn] = '\0';
    v->u.s.n = an + bn;
    return v;
}

/* Clamp half-open slices as in the native runtime. */
Yv *ys_slice(const Yv *s, ylong lo, ylong hi) {
    if (!s || yv_tag(s) != Y_STR) { return ys(""); }
    ylong n = (ylong)s->u.s.n;
    if (lo < 0) lo = 0;
    if (hi > n) hi = n;
    if (hi <= lo) { return ys(""); }
    return ys_n(s->u.s.p + lo, (size_t)(hi - lo));
}

int ys_cmp(const Yv *a, const Yv *b) {
    /* length-aware strcmp: common prefix first, then the lengths */
    size_t an = (a && yv_tag(a) == Y_STR) ? a->u.s.n : 0;
    size_t bn = (b && yv_tag(b) == Y_STR) ? b->u.s.n : 0;
    size_t n = an < bn ? an : bn;
    int c = n ? memcmp(a->u.s.p, b->u.s.p, n) : 0;
    if (c) return c;
    return an < bn ? -1 : (an > bn ? 1 : 0);
}

Yv *ys_trim(const Yv *x) {
    if (!x || yv_tag(x) != Y_STR) { return ys(""); }
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
    if (!arr || yv_tag(arr) != Y_ARR || !sep || yv_tag(sep) != Y_STR) { return ys(""); }
    /* a str element is used as it is; anything else is rendered once */
    size_t n = arr->u.a.len;
    Yv **parts = n ? yalloc(sizeof(Yv *) * n) : NULL;
    size_t total = 1;
    for (size_t i = 0; i < n; i++) {
        Yv *e = arr->u.a.items[i];
        parts[i] = (e && yv_tag(e) == Y_STR) ? e : ys_tostring(e);
        total += parts[i]->u.s.n + sep->u.s.n;
    }
    char *buf = yalloc_bytes(total + 1);
    size_t pos = 0;
    for (size_t i = 0; i < n; i++) {
        if (i > 0) {
            memcpy(buf + pos, sep->u.s.p, sep->u.s.n);
            pos += sep->u.s.n;
        }
        memcpy(buf + pos, parts[i]->u.s.p, parts[i]->u.s.n);
        pos += parts[i]->u.s.n;
    }
    buf[pos] = '\0';
    return ys_own(buf, pos);
}

/* first index of sub at or after `from` in s[0..n), or (size_t)-1.
   An empty needle never matches (mirrors rt.y's y_str_index, which
   requires m > 0 and otherwise leaves `found` at -1). */
static size_t ymem_find(const char *s, size_t n, const char *sub, size_t m,
                        size_t from) {
    if (m == 0) return (size_t)-1;
    if (m > n) return (size_t)-1;
    for (size_t i = from; i + m <= n; i++) {
        if (memcmp(s + i, sub, m) == 0) return i;
    }
    return (size_t)-1;
}

Yv *ys_split(const Yv *s, const Yv *delim) {
    Yv *out = yarr_new();
    if (!s || yv_tag(s) != Y_STR || !delim || yv_tag(delim) != Y_STR) { return out; }
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

ylong ys_index_of(const Yv *s, const Yv *sub) {
    if (!s || yv_tag(s) != Y_STR || !sub || yv_tag(sub) != Y_STR) { return -1; }
    size_t i = ymem_find(s->u.s.p, s->u.s.n, sub->u.s.p, sub->u.s.n, 0);
    return i == (size_t)-1 ? -1 : (ylong)i;
}

ylong ys_last_index_of(const Yv *s, const Yv *sub) {
    if (!s || yv_tag(s) != Y_STR || !sub || yv_tag(sub) != Y_STR) { return -1; }
    size_t n = s->u.s.n, m = sub->u.s.n;
    if (m == 0) { return -1; } /* an empty needle never matches (rt.y) */
    for (ylong i = (ylong)(n - m); i >= 0; i--) {
        if (memcmp(s->u.s.p + i, sub->u.s.p, m) == 0) { return i; }
    }
    return -1;
}

/* Out-of-range matches are false. */
static int ys_at(const Yv *s, const Yv *p, ylong at) {
    if (!s || yv_tag(s) != Y_STR || !p || yv_tag(p) != Y_STR) { return 0; }
    size_t m = p->u.s.n;
    if (at < 0 || (size_t)at + m > s->u.s.n) { return 0; }
    return m == 0 || memcmp(s->u.s.p + at, p->u.s.p, m) == 0;
}

int ys_starts_with(const Yv *s, const Yv *p) { return ys_at(s, p, 0); }

int ys_ends_with(const Yv *s, const Yv *p) {
    if (!s || yv_tag(s) != Y_STR || !p || yv_tag(p) != Y_STR) { return 0; }
    return ys_at(s, p, (ylong)(s->u.s.n - p->u.s.n));
}

ylong ys_ord(const Yv *x) {
    if (!x || yv_tag(x) != Y_STR || x->u.s.n == 0) { return -1; }
    return (ylong)(unsigned char)x->u.s.p[0];
}

ylong ys_byte_at(const Yv *s, ylong i) {
    if (!s || yv_tag(s) != Y_STR || i < 0 || (size_t)i >= s->u.s.n) {
        fprintf(stderr, "runtime error: index out of bounds\n");
        exit(1);
    }
    return (ylong)(unsigned char)s->u.s.p[i];
}

Yv *ys_chr(ylong v) {
    char buf[2];
    buf[0] = (char)(v & 0xFF);
    buf[1] = '\0';
    return ys_n(buf, 1);
}

static Yv *ys_long(ylong v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)v);
    return ys_cstr(buf);
}

Yv *ys_tolong_opt(const Yv *x) {
    if (!x || yv_tag(x) != Y_STR) return yv_none();
    const char *p = x->u.s.p;
    ylong n = (ylong)x->u.s.n;
    ylong i = 0;
    while (i < n && (p[i] == 32 || (p[i] >= 9 && p[i] <= 13))) { i = i + 1; }
    int neg = 0;
    if (i < n) {
        unsigned char sg = (unsigned char)p[i];
        if (sg == 45 || sg == 43) {
            neg = sg == 45;
            i = i + 1;
        }
    }
    ylong start = i;
    ylong mag = 0;
    int ovf = 0;
    int go = 1;
    while (i < n && go) {
        int c = (unsigned char)p[i];
        if (c < 48 || c > 57) { go = 0; }
        else {
            ylong d = c - 48;
            if (neg) {
                if (mag < -922337203685477580LL) { ovf = 1; }
                else if (mag == -922337203685477580LL && d > 8) { ovf = 1; }
                else { mag = mag * 10 - d; }
            } else {
                if (mag > 922337203685477580LL) { ovf = 1; }
                else if (mag == 922337203685477580LL && d > 7) { ovf = 1; }
                else { mag = mag * 10 + d; }
            }
            if (ovf) { go = 0; } else { i = i + 1; }
        }
    }
    if (ovf || i == start) { return yv_none(); }
    while (i < n && (p[i] == 32 || (p[i] >= 9 && p[i] <= 13))) { i = i + 1; }
    if (i < n) { return yv_none(); }
    return yv_long(mag);
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
    char *esc = yalloc_bytes(len + 1);
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
    if (!v) { return ys("none"); }
    switch (yv_tag(v)) {
    case Y_NONE: return ys("none");
    case Y_BOOL: return ys_cstr(v->u.b ? "true" : "false");
    case Y_LONG: return ys_long(yv_l(v));
    case Y_FLOAT: {
        snprintf(buf, cap, "%f", v->u.f);
        return ys_cstr(buf);
    }
    case Y_STR: return (Yv *)v; /* immutable: the value itself */
    case Y_ARR: {
        /* "[e0, e1, ...]" — the format the native tostring prints */
        size_t n = v->u.a.len;
        Yv **parts = n ? yalloc(sizeof(Yv *) * n) : NULL;
        size_t total = 2;
        for (size_t i = 0; i < n; i++) {
            parts[i] = ys_tostring(ya_get(v, (ylong)i));
            total += parts[i]->u.s.n + 2;
        }
        char *b = yalloc_bytes(total + 1);
        size_t pos = 0;
        b[pos++] = '[';
        for (size_t i = 0; i < n; i++) {
            if (i > 0) { b[pos++] = ','; b[pos++] = ' '; }
            size_t el = parts[i]->u.s.n;
            memcpy(b + pos, parts[i]->u.s.p, el);
            pos += el;
        }
        b[pos++] = ']';
        b[pos] = '\0';
        return ys_own(b, pos);
    }
    case Y_REC: {
        size_t n = v->u.r.len;
        Yv **parts = n ? yalloc(sizeof(Yv *) * n) : NULL;
        char **keys = n ? yalloc(sizeof(char *) * n) : NULL;
        size_t total = 3;
        for (size_t i = 0; i < n; i++) {
            keys[i] = escape_str(v->u.r.keys[i]);
            parts[i] = ys_tostring(v->u.r.vals[i]);
            total += strlen(keys[i]) + parts[i]->u.s.n + 4;
        }
        char *b = yalloc_bytes(total + 1);
        size_t pos = 0;
        b[pos++] = '{';
        for (size_t i = 0; i < n; i++) {
            if (i > 0) { b[pos++] = ','; b[pos++] = ' '; }
            size_t kl = strlen(keys[i]);
            memcpy(b + pos, keys[i], kl);
            pos += kl;
            b[pos++] = ':';
            b[pos++] = ' ';
            size_t el = parts[i]->u.s.n;
            memcpy(b + pos, parts[i]->u.s.p, el);
            pos += el;
        }
        b[pos++] = '}';
        b[pos] = '\0';
        return ys_own(b, pos);
    }
    }
    return ys("none");
}

static void ya_grow(Yv *a, size_t need) {
    if (need <= a->u.a.cap) return;
    size_t cap = a->u.a.cap < 8 ? 8 : a->u.a.cap * 2;
    while (cap < need) cap *= 2;
    size_t stride = a->u.a.bytewise == 2 ? 1 : sizeof(Yv *);
    Yv **items = a->u.a.bytewise == 2 ? yalloc_bytes(cap) : yalloc(sizeof(Yv *) * cap);
    if (a->u.a.len) memcpy(items, a->u.a.items, stride * a->u.a.len);
    a->u.a.items = items;
    a->u.a.cap = cap;
}

Yv *yav(size_t n, ...) {
    Yv *v = yarr_new();
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

Yv *ya_rep(Yv *x, ylong n) {
    Yv *v = yarr_new();
    if (n > 0) {
        ya_grow(v, (size_t)n);
        for (ylong i = 0; i < n; i++) v->u.a.items[i] = x;
        v->u.a.len = (size_t)n;
    }
    return v;
}

Yv *ya_bytes_zero(ylong n) {
    Yv *v = yarr_new();
    v->u.a.bytewise = 2;
    if (n > 0) {
        v->u.a.items = yalloc_bytes((size_t)n);
        memset(v->u.a.items, 0, (size_t)n);
        v->u.a.len = v->u.a.cap = (size_t)n;
    }
    return v;
}

Yv *ya_get(const Yv *a, ylong i) {
    if (!a || yv_tag(a) != Y_ARR || i < 0 || (size_t)i >= a->u.a.len) {
        fprintf(stderr, "runtime error: index out of bounds\n");
        exit(1);
    }
    return a->u.a.bytewise == 2 ? yv_long(((unsigned char *)a->u.a.items)[i]) : a->u.a.items[i];
}

void ya_set(Yv *a, ylong i, Yv *v) {
    if (!a || yv_tag(a) != Y_ARR || i < 0 || (size_t)i >= a->u.a.len) {
        fprintf(stderr, "runtime error: index out of bounds\n");
        exit(1);
    }
    if (a->u.a.bytewise == 2) ((unsigned char *)a->u.a.items)[i] = (unsigned char)yv_l(v);
    else a->u.a.items[i] = v;
}

Yv *ya_push(Yv *a, Yv *v) {
    if (!a || yv_tag(a) != Y_ARR) a = yarr_new();
    ya_grow(a, a->u.a.len + 1);
    if (a->u.a.bytewise == 2) ((unsigned char *)a->u.a.items)[a->u.a.len++] = (unsigned char)yv_l(v);
    else a->u.a.items[a->u.a.len++] = v;
    return a;
}

Yv *ya_slice(const Yv *a, ylong lo, ylong hi) {
    Yv *v = yarr_new();
    if (!a || yv_tag(a) != Y_ARR) return v;
    v->u.a.bytewise = a->u.a.bytewise;
    ylong n = (ylong)a->u.a.len;
    if (lo < 0) lo = 0;
    if (lo > n) lo = n;
    if (hi < 0 || hi > n) hi = n;
    if (hi < lo) hi = lo;
    ylong cnt = hi - lo;
    if (cnt > 0) {
        ya_grow(v, (size_t)cnt);
        size_t stride = a->u.a.bytewise == 2 ? 1 : sizeof(Yv *);
        memcpy(v->u.a.items, (char *)a->u.a.items + lo * stride, (size_t)cnt * stride);
        v->u.a.len = (size_t)cnt;
    }
    return v;
}

static void ym_grow(Yv *m, size_t need) {
    if (need <= m->u.r.cap) return;
    size_t cap = m->u.r.cap < 8 ? 8 : m->u.r.cap * 2;
    while (cap < need) cap *= 2;
    char **keys = yalloc(sizeof(char *) * cap);
    Yv **vals = yalloc(sizeof(Yv *) * cap);
    if (m->u.r.len) {
        memcpy(keys, m->u.r.keys, sizeof(char *) * m->u.r.len);
        memcpy(vals, m->u.r.vals, sizeof(Yv *) * m->u.r.len);
    }
    m->u.r.keys = keys;
    m->u.r.vals = vals;
    m->u.r.cap = cap;
}

Yv *yr(size_t n, ...) {
    /* the header and n key/value slots in one block, exactly sized (a
     * record rarely gains a field after it is made; ym_grow if it does) */
    char *blk = yalloc(sizeof(Yv) + n * (sizeof(char *) + sizeof(Yv *)));
    Yv *v = (Yv *)blk;
    v->tag = Y_REC;
    v->u.r.keys = n ? (char **)(blk + sizeof(Yv)) : NULL;
    v->u.r.vals = n ? (Yv **)(blk + sizeof(Yv) + n * sizeof(char *)) : NULL;
    v->u.r.len = 0;
    v->u.r.cap = n;
    va_list ap;
    va_start(ap, n);
    for (size_t i = 0; i < n; i++) {
        const char *k = va_arg(ap, const char *);
        Yv *val = va_arg(ap, Yv *);
        yr_set(v, k, val);
    }
    va_end(ap);
    return v;
}

static inline int yk_eq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

Yv *yr_get(const Yv *m, const char *key) {
    if (m && yv_tag(m) == Y_REC) {
        for (size_t i = 0; i < m->u.r.len; i++) {
            if (yk_eq(m->u.r.keys[i], key)) return m->u.r.vals[i];
        }
    }
    return yv_none();
}

/* Record keys borrow storage that the caller keeps alive. */
Yv *yr_set(Yv *m, const char *key, Yv *v) {
    if (!m || yv_tag(m) != Y_REC) return m;
    for (size_t i = 0; i < m->u.r.len; i++) {
        if (yk_eq(m->u.r.keys[i], key)) {
            m->u.r.vals[i] = v;
            return m;
        }
    }
    ym_grow(m, m->u.r.len + 1);
    m->u.r.keys[m->u.r.len] = (char *)key;
    m->u.r.vals[m->u.r.len] = v;
    m->u.r.len++;
    return m;
}

int yr_has(const Yv *m, const char *key) {
    if (!m || yv_tag(m) != Y_REC) return 0;
    for (size_t i = 0; i < m->u.r.len; i++) {
        if (yk_eq(m->u.r.keys[i], key)) return 1;
    }
    return 0;
}

int yv_eq(const Yv *a, const Yv *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (yv_tag(a) != yv_tag(b)) return 0;
    switch (yv_tag(a)) {
    case Y_NONE: return 1;
    case Y_BOOL: return a->u.b == b->u.b;
    case Y_LONG: return yv_l(a) == yv_l(b);
    case Y_FLOAT: return a->u.f == b->u.f;
    case Y_STR: return strcmp(a->u.s.p, b->u.s.p) == 0;
    case Y_ARR: {
        if (a->u.a.len != b->u.a.len) return 0;
        for (size_t i = 0; i < a->u.a.len; i++)
            if (!yv_eq(ya_get(a, (ylong)i), ya_get(b, (ylong)i))) return 0;
        return 1;
    }
    case Y_REC: {
        if (a->u.r.len != b->u.r.len) return 0;
        for (size_t i = 0; i < a->u.r.len; i++) {
            if (strcmp(a->u.r.keys[i], b->u.r.keys[i]) != 0) return 0;
            if (!yv_eq(a->u.r.vals[i], b->u.r.vals[i])) return 0;
        }
        return 1;
    }
    }
    return 0;
}

/* Y `str` values may contain NUL bytes (ys_n / from_bytes), and the native
   runtime writes len(s) bytes — so every output path here is length-based,
   never strlen/fputs. */
void puts_(const Yv *s) {
    if (s && yv_tag(s) == Y_STR) fwrite(s->u.s.p, 1, s->u.s.n, stdout);
    else fputs("none", stdout);
    fflush(stdout);
}

void eputs_(const Yv *s) {
    if (s && yv_tag(s) == Y_STR) fwrite(s->u.s.p, 1, s->u.s.n, stderr);
    else fputs("none", stderr);
    fflush(stderr);
}

void exit_(ylong code) { exit((int)code); }

static Yv *read_stream(FILE *f) {
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap + 1);
    if (!buf) yoom();
    for (;;) {
        if (len == cap) {
            size_t ncap = cap * 2;
            char *nb = realloc(buf, ncap + 1);
            if (!nb) yoom();
            buf = nb;
            cap = ncap;
        }
        size_t rd = fread(buf + len, 1, cap - len, f);
        len += rd;
        if (rd == 0) break; /* eof, or a read error: both end the stream */
    }
    buf[len] = '\0';
    return ys_own(buf, len);
}

Yv *read_file(const Yv *path) {
    if (!path || yv_tag(path) != Y_STR) return yv_none();
    FILE *f = fopen(path->u.s.p, "rb");
    if (!f) return yv_none();
    /* A directory opens for reading and read(2) refuses one with EISDIR,
       which the fread below sees only as end-of-file -- so read_file("dir")
       answered "" and `ycc <a dir>` compiled that into an empty executable.
       Use one stat to distinguish a directory from an empty file.
       Only a directory is refused here: a fifo is read to the end. */
    {
        struct stat st;
        if (fstat(fileno(f), &st) == 0 && S_ISDIR(st.st_mode)) {
            fclose(f);
            return yv_none();
        }
    }
    ylong sz = 0;
    if (fseek(f, 0, SEEK_END) != 0 || (sz = ftell(f)) < 0) {
        Yv *v = read_stream(f);
        fclose(f);
        return v;
    }
    fseek(f, 0, SEEK_SET);
    char *buf = yalloc_bytes((size_t)sz + 1);
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    return ys_n(buf, rd);
}

/* A buffered write only fails when the buffer is flushed, so `fclose`'s
 * return is the one that says whether the bytes landed -- discarding it (as
 * this did) is how `cycc -o /dev/full` exited 0 while `ycc` reported the
 * failure: report a buffered write failure before returning. */
static int close_written(FILE *f, size_t wr, size_t n) {
    int rc = fclose(f); /* flushes; EOF on a write error */
    return wr == n && rc == 0;
}

int write_file(const Yv *path, const Yv *content) {
    if (!path || yv_tag(path) != Y_STR || !content || yv_tag(content) != Y_STR) return 0;
    FILE *f = fopen(path->u.s.p, "wb");
    if (!f) return 0;
    size_t n = content->u.s.n; /* length-based: a str may contain NULs */
    size_t wr = fwrite(content->u.s.p, 1, n, f);
    return close_written(f, wr, n);
}

int remove_file(const Yv *path) {
    if (!path || yv_tag(path) != Y_STR) return 0;
    return unlink(path->u.s.p) == 0;
}

int write_bytes(const Yv *path, const Yv *bytearr, ylong mode) {
    if (!path || yv_tag(path) != Y_STR || !bytearr || yv_tag(bytearr) != Y_ARR) return 0;
    size_t n = bytearr->u.a.len;
    char *buf = yalloc_bytes(n ? n : 1);
    for (size_t i = 0; i < n; i++) {
        Yv *e = ya_get(bytearr, (ylong)i);
        buf[i] = (char)(e && yv_tag(e) == Y_LONG ? (yv_l(e) & 0xFF) : 0);
    }
    FILE *f = fopen(path->u.s.p, "wb");
    if (!f) return 0;
    size_t wr = fwrite(buf, 1, n, f);
    if (!close_written(f, wr, n)) return 0;
    if (mode >= 0) {
        /* only a regular file has a mode to set (not a device or a pipe) */
        struct stat sb;
        if (stat(path->u.s.p, &sb) == 0 && S_ISREG(sb.st_mode) &&
            chmod(path->u.s.p, (mode_t)mode) != 0)
            return 0;
    }
    return 1;
}

static Yv *g_argv = NULL;

void yv_set_argv(int argc, char **argv) {
    Yv *a = yarr_new();
    for (int i = 0; i < argc; i++) ya_push(a, ys_cstr(argv[i]));
    g_argv = a;
}

Yv *argv_(void) { return g_argv ? g_argv : yav(0); }

ylong clock_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ylong)ts.tv_sec * 1000000L + ts.tv_nsec / 1000;
}

ylong heap_used(void) { return g_heap_used; }

Yv *bytes_of(const Yv *s) {
    size_t n = (s && yv_tag(s) == Y_STR) ? s->u.s.n : 0;
    Yv *v = ya_bytes_zero((ylong)n);
    if (n) memcpy(v->u.a.items, s->u.s.p, n);
    return v;
}

/* fs.getenv(name): the value, or none. The name is a Y string (NUL-terminated
 * by ys_n), so getenv can take it directly. */
Yv *fs_getenv(const Yv *name) {
    if (!name || yv_tag(name) != Y_STR) return yv_none();
    const char *v = getenv(name->u.s.p);
    return v ? ys_cstr(v) : yv_none();
}

static const char *y_path(const Yv *p) {
    return (p && yv_tag(p) == Y_STR) ? p->u.s.p : NULL;
}

Yv *fs_make_dir(const Yv *p, ylong mode) {
    const char *path = y_path(p);
    if (!path) return yv_bool(0);
    return yv_bool(mkdir(path, (mode_t)mode) == 0);
}

/* mkdir -p: every component, ignoring "already there". */
Yv *fs_make_dirs(const Yv *p) {
    const char *path = y_path(p);
    if (!path || !*path) return yv_bool(0);
    size_t n = strlen(path);
    char *buf = malloc(n + 1);
    if (!buf) yoom();
    memcpy(buf, path, n + 1);
    int ok = 1;
    for (size_t i = 1; i <= n; i++) {
        if (buf[i] == '/' || buf[i] == 0) {
            char save = buf[i];
            buf[i] = 0;
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) ok = 0;
            buf[i] = save;
            if (!ok) break;
        }
    }
    free(buf);
    return yv_bool(ok);
}

Yv *fs_is_dir(const Yv *p) {
    const char *path = y_path(p);
    struct stat st;
    return yv_bool(path && stat(path, &st) == 0 && S_ISDIR(st.st_mode));
}

Yv *fs_is_file(const Yv *p) {
    const char *path = y_path(p);
    struct stat st;
    return yv_bool(path && stat(path, &st) == 0 && S_ISREG(st.st_mode));
}

Yv *fs_remove_dir(const Yv *p) {
    const char *path = y_path(p);
    return yv_bool(path && rmdir(path) == 0);
}

Yv *fs_open_file(const Yv *p, const Yv *how) {
    const char *path = y_path(p);
    const char *m = (how && yv_tag(how) == Y_STR) ? how->u.s.p : "r";
    if (!path) return yv_long(-1);
    int flags;
    if (strchr(m, 'w')) flags = O_WRONLY | O_CREAT | O_TRUNC;
    else if (strchr(m, 'a')) flags = O_WRONLY | O_CREAT | O_APPEND;
    else if (strchr(m, '+')) flags = O_RDWR;
    else flags = O_RDONLY;
    int fd = open(path, flags, 0644);
    return yv_long(fd < 0 ? -1 : fd);
}

Yv *fs_read_some(ylong fd, ylong cap) {
    if (cap <= 0) return bytes_of(ys(""));
    char *buf = malloc((size_t)cap);
    if (!buf) yoom();
    ssize_t n;
    do { n = read((int)fd, buf, (size_t)cap); } while (n < 0 && errno == EINTR);
    if (n < 0) n = 0;
    Yv *s = ys_n(buf, (size_t)n);
    free(buf);
    return bytes_of(s);
}

Yv *fs_close_file(ylong fd) {
    return yv_bool(close((int)fd) == 0);
}

Yv *fs_read_bytes(const Yv *p) {
    const char *path = y_path(p);
    if (!path) return yv_none();
    int fd = open(path, O_RDONLY);
    if (fd < 0) return yv_none();
    Yv *b = read_all_bytes((ylong)fd);
    close(fd);
    return b;
}

Yv *fs_list_dir(const Yv *p) {
    const char *path = y_path(p);
    if (!path) return yv_none();
    DIR *d = opendir(path);
    if (!d) return yv_none();
    Yv *a = ya_rep(yv_none(), 0);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        ya_push(a, ys_cstr(e->d_name));
    }
    closedir(d);
    return a;
}

/* fd -> [byte], to EOF. The meta generator's parent reads its child's pipe
 * this way: a read(2) loop, not a stdio stream (a pipe has no size). */
Yv *read_all_bytes(ylong fd) {
    size_t cap = 65536, n = 0;
    char *buf = malloc(cap);
    if (!buf) yoom();
    for (;;) {
        if (n == cap) {
            char *nb = realloc(buf, cap * 2);
            if (!nb) { free(buf); yoom(); }
            buf = nb;
            cap *= 2;
        }
        ssize_t k = read((int)fd, buf + n, cap - n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) break;
        n += (size_t)k;
    }
    Yv *s = ys_n(n ? buf : "", n);
    free(buf);
    return bytes_of(s);
}

/* [byte] (or str) -> fd, all of it. A short write is retried; a failure is
 * false, and the caller turns that into its own diagnostic. */
int write_data(ylong fd, const Yv *a) {
    if (!a) return 0;
    const unsigned char *p = NULL;
    unsigned char *tmp = NULL;
    size_t n = 0;
    if (yv_tag(a) == Y_STR) {
        p = (const unsigned char *)a->u.s.p;
        n = a->u.s.n;
    } else if (yv_tag(a) == Y_ARR) {
        n = a->u.a.len;
        if (a->u.a.bytewise == 2) {
            p = (const unsigned char *)a->u.a.items;
        } else {
            tmp = malloc(n ? n : 1);
            if (!tmp) yoom();
            for (size_t i = 0; i < n; i++) {
                Yv *e = a->u.a.items[i];
                tmp[i] = (unsigned char)(e && yv_tag(e) == Y_LONG ? (yv_l(e) & 0xFF) : 0);
            }
            p = tmp;
        }
    } else {
        return 0;
    }
    int ok = 1;
    size_t off = 0;
    while (ok && off < n) {
        ssize_t k = write((int)fd, p + off, n - off);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) ok = 0; else off += (size_t)k;
    }
    free(tmp);
    return ok;
}

Yv *from_bytes(const Yv *a) {
    if (!a || yv_tag(a) != Y_ARR) { return ys(""); }
    size_t n = a->u.a.len;
    if (a->u.a.bytewise == 2) return ys_n(n ? (const char *)a->u.a.items : "", n);
    char *buf = yalloc_bytes(n + 1);
    for (size_t i = 0; i < n; i++) {
        Yv *e = a->u.a.items[i];
        buf[i] = (char)(e && yv_tag(e) == Y_LONG ? (yv_l(e) & 0xFF) : 0);
    }
    buf[n] = '\0';
    return ys_n(buf, n);
}

ylong byte_len(const Yv *s) {
    return (s && yv_tag(s) == Y_STR) ? (ylong)s->u.s.n : 0;
}
