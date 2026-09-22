#include "module.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_IMPORT_DEPTH 32

/* ── small string builder ─────────────────────────────────────────────── */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} SB;

static void sb_init(SB *sb) {
    sb->cap = 256;
    sb->len = 0;
    sb->data = malloc(sb->cap);
    sb->data[0] = '\0';
}

static void sb_reserve(SB *sb, size_t extra) {
    if (sb->len + extra + 1 > sb->cap) {
        while (sb->len + extra + 1 > sb->cap) sb->cap *= 2;
        sb->data = realloc(sb->data, sb->cap);
    }
}

static void sb_append(SB *sb, const char *s) {
    size_t n = strlen(s);
    sb_reserve(sb, n);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void sb_append_n(SB *sb, const char *s, size_t n) {
    sb_reserve(sb, n);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

/* ── path helpers ─────────────────────────────────────────────────────── */

/* Return the directory portion of a path (malloc'd). "." if none. */
static char *path_dir(const char *path) {
    const char *slash = strrchr(path, '/');
    if (!slash) return strdup(".");
    if (slash == path) return strdup("/");
    size_t n = (size_t)(slash - path);
    char *d = malloc(n + 1);
    memcpy(d, path, n);
    d[n] = '\0';
    return d;
}

/* Join dir + "/" + rel, handling rel that is already absolute. malloc'd. */
static char *path_join(const char *dir, const char *rel) {
    if (rel[0] == '/') return strdup(rel);
    size_t n = strlen(dir) + 1 + strlen(rel) + 1;
    char *out = malloc(n);
    snprintf(out, n, "%s/%s", dir, rel);
    return out;
}

static char *read_whole_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)sz + 1);
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    return buf;
}

/* ── token-ish scanners ───────────────────────────────────────────────── */

static const char *skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

/* If `p` starts with keyword `kw` (followed by non-identifier char),
 * return pointer past it; else NULL. */
static const char *match_kw(const char *p, const char *kw) {
    size_t n = strlen(kw);
    if (strncmp(p, kw, n) != 0) return NULL;
    char c = p[n];
    if (isalnum((unsigned char)c) || c == '_') return NULL;
    return p + n;
}

static const char *parse_ident(const char *p, char **out) {
    p = skip_ws(p);
    const char *start = p;
    while (isalnum((unsigned char)*p) || *p == '_') p++;
    if (p == start) return NULL;
    size_t n = (size_t)(p - start);
    *out = malloc(n + 1);
    memcpy(*out, start, n);
    (*out)[n] = '\0';
    return p;
}

/* Parse a "..." or '...' string literal; returns malloc'd unescaped content. */
static const char *parse_string(const char *p, char **out) {
    p = skip_ws(p);
    if (*p != '"' && *p != '\'') return NULL;
    char quote = *p++;
    SB sb;
    sb_init(&sb);
    while (*p && *p != quote) {
        if (*p == '\\' && p[1]) {
            p++;
            char c = *p;
            switch (c) {
            case 'n': c = '\n'; break;
            case 't': c = '\t'; break;
            case 'r': c = '\r'; break;
            default: break; /* keep literal */
            }
            sb_reserve(&sb, 1);
            sb.data[sb.len++] = c;
            sb.data[sb.len] = '\0';
            p++;
        } else {
            sb_reserve(&sb, 1);
            sb.data[sb.len++] = *p++;
            sb.data[sb.len] = '\0';
        }
    }
    if (*p != quote) { free(sb.data); return NULL; }
    *out = sb.data;
    return p + 1;
}

/* ── core ─────────────────────────────────────────────────────────────── */

/* Process a single module body: recursively expand imports and rewrite a
 * trailing `export { ... };` into a map literal `{ a: a, ... }`. */
static char *process_body(const char *source, const char *base_dir,
                          int depth) {
    if (depth > MAX_IMPORT_DEPTH) {
        fprintf(stderr, "module: import depth exceeded (cycle?)\n");
        return NULL;
    }

    SB out;
    sb_init(&out);
    const char *p = source;

    while (*p) {
        const char *line_start = p;
        const char *q = skip_ws(p);

        /* import NAME from "PATH"; */
        const char *r = match_kw(q, "import");
        if (r) {
            char *name = NULL;
            const char *s = parse_ident(r, &name);
            if (s) {
                s = skip_ws(s);
                s = match_kw(s, "from");
            }
            char *path = NULL;
            if (s) s = parse_string(s, &path);
            if (s) {
                s = skip_ws(s);
                if (*s == ';') s++;
                /* resolve + read + recursively preprocess the module */
                char *full = path_join(base_dir, path);
                char *mod_src = read_whole_file(full);
                if (!mod_src) {
                    fprintf(stderr, "module: cannot open import '%s' (resolved "
                                    "to '%s')\n", path, full);
                    free(full); free(name); free(path); free(out.data);
                    return NULL;
                }
                char *mod_dir = path_dir(full);
                char *processed = process_body(mod_src, mod_dir, depth + 1);
                free(mod_src); free(mod_dir); free(full);
                if (!processed) {
                    free(name); free(path); free(out.data);
                    return NULL;
                }
                sb_append(&out, "let ");
                sb_append(&out, name);
                sb_append(&out, " = {\n");
                sb_append(&out, processed);
                sb_append(&out, "\n};\n");
                free(processed); free(name); free(path);
                p = s;
                continue;
            }
            free(name);
            free(path);
        }

        /* export { a, b };  ->  { a: a, b: b };  (only meaningful at end) */
        r = match_kw(q, "export");
        if (r) {
            const char *s = skip_ws(r);
            if (*s == '{') {
                s++;
                SB map;
                sb_init(&map);
                sb_append(&map, "{ ");
                int first = 1;
                while (1) {
                    char *id = NULL;
                    const char *t = parse_ident(s, &id);
                    if (!t) { free(id); break; }
                    if (!first) sb_append(&map, ", ");
                    sb_append(&map, id);
                    sb_append(&map, ": ");
                    sb_append(&map, id);
                    free(id);
                    first = 0;
                    s = skip_ws(t);
                    if (*s == ',') { s++; continue; }
                    break;
                }
                s = skip_ws(s);
                if (*s == '}') s++;
                s = skip_ws(s);
                if (*s == ';') s++;
                sb_append(&map, " }");
                /* leading whitespace of the original line is preserved */
                sb_append_n(&out, line_start, (size_t)(q - line_start));
                sb_append(&out, map.data);
                sb_append(&out, "\n");
                free(map.data);
                p = s;
                continue;
            }
        }

        /* default: copy one line verbatim */
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
        sb_append_n(&out, line_start, (size_t)(p - line_start));
    }

    return out.data;
}

char *module_preprocess(const char *source, const char *base_dir, int depth) {
    return process_body(source, base_dir, depth);
}
