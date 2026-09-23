#include "runtime.h"
#include <inttypes.h>
#include <limits.h>
#include <malloc.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

/* ── Self-contained runtime embedding (C layer) ──────────────────────────
 * When compiled with -DY_EMBED_RUNTIME, the runtime source (runtime.c/h) is
 * baked into the binary as C string constants (embedded_runtime.inc, generated
 * at build time). y_ensure_runtime() extracts them to a temp dir so a compiled
 * program can recompile Y code with no source tree / YCC_RUNTIME_DIR. The Y
 * layer never handles these bytes — it just calls the builtins below. */
#ifdef Y_EMBED_RUNTIME
#include "embedded_runtime.inc"
#else
static const char y_embedded_runtime_c[] = "";
static const char y_embedded_runtime_h[] = "";
#endif

#ifndef RUNTIME_DIR
#define RUNTIME_DIR "."
#endif

/* Extract the embedded runtime to a temp dir; return the dir (static buffer).
 * Falls back to RUNTIME_DIR (the source tree) when not built with embedding. */
const char *y_ensure_runtime(void) {
    static char dir[256];
    if (y_embedded_runtime_c[0] != '\0') {
        snprintf(dir, sizeof(dir), "/tmp/ycc_runtime_%d", (int)getpid());
        char cmd[512];
        snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", dir);
        if (system(cmd) != 0) return RUNTIME_DIR;
        char path[300];
        snprintf(path, sizeof(path), "%s/runtime.c", dir);
        FILE *f = fopen(path, "w");
        if (f) { fputs(y_embedded_runtime_c, f); fclose(f); }
        snprintf(path, sizeof(path), "%s/runtime.h", dir);
        f = fopen(path, "w");
        if (f) { fputs(y_embedded_runtime_h, f); fclose(f); }
        return dir;
    }
    return RUNTIME_DIR;
}

/* Emit a C string-literal body (escaped) for a file's contents. */
static void emit_c_escaped(FILE *out, const char *s) {
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        switch (c) {
        case '\\': fputs("\\\\", out); break;
        case '"':  fputs("\\\"", out); break;
        case '\n': fputs("\\n", out); break;
        case '\t': fputs("\\t", out); break;
        case '\r': fputs("\\r", out); break;
        default:
            if (c < 32 || c > 126) fprintf(out, "\\%03o", c);
            else fputc(c, out);
        }
    }
}

/* Generate embedded_runtime.inc in out_dir from the runtime source in
 * src_dir. Lets a self-contained binary regenerate the embedding when it
 * recompiles, so self-containment propagates across self-compilation. */
int y_gen_embedded_runtime(const char *src_dir, const char *out_dir) {
    char path[512];
    snprintf(path, sizeof(path), "%s/embedded_runtime.inc", out_dir);
    FILE *out = fopen(path, "w");
    if (!out) return -1;
    const char *files[2] = { "runtime.c", "runtime.h" };
    const char *vars[2] = { "y_embedded_runtime_c", "y_embedded_runtime_h" };
    for (int i = 0; i < 2; i++) {
        char src[512];
        snprintf(src, sizeof(src), "%s/%s", src_dir, files[i]);
        FILE *f = fopen(src, "rb");
        if (!f) { fclose(out); return -1; }
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        char *buf = malloc((size_t)sz + 1);
        size_t rd = fread(buf, 1, (size_t)sz, f);
        buf[rd] = '\0';
        fclose(f);
        fprintf(out, "static const char %s[] = \"", vars[i]);
        emit_c_escaped(out, buf);
        fprintf(out, "\";\n");
        free(buf);
    }
    fclose(out);
    return 0;
}

/* ── builtins wrapping the above (callable from Y) ─────────────────────── */

YValue *y_builtin_ensure_runtime(YScope *closure, YValue **args, size_t argc) {
    (void)closure; (void)args; (void)argc;
    return y_mk_str(y_ensure_runtime());
}

YValue *y_builtin_gen_embedded_runtime(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_STR)
        return y_mk_long(-1);
    return y_mk_long(y_gen_embedded_runtime(args[0]->data.s, args[1]->data.s));
}


/* Ignore SIGPIPE so tcp_write to a closed socket returns an error instead of
 * killing the process. Installed once at first tcp_listen call. */
static int g_sigpipe_ignored = 0;
static void ignore_sigpipe_once(void) {
    if (!g_sigpipe_ignored) {
        signal(SIGPIPE, SIG_IGN);
        g_sigpipe_ignored = 1;
    }
}

/* ── Constructors ───────────────────────────────────────────────────────── */

YValue *y_mk_long(long v) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_LONG;
    val->data.l = v;
    return val;
}

YValue *y_mk_float(double v) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_FLOAT;
    val->data.f = v;
    return val;
}

YValue *y_mk_bool(bool v) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_BOOL;
    val->data.b = v;
    return val;
}

YValue *y_mk_str(const char *s) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_STR;
    val->data.s = strdup(s);
    return val;
}

YValue *y_mk_str_n(const char *s, size_t len) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_STR;
    val->data.s = malloc(len + 1);
    memcpy(val->data.s, s, len);
    val->data.s[len] = '\0';
    return val;
}

YValue *y_mk_null(void) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_NULL;
    return val;
}

YValue *y_mk_arr(YValue **elements, size_t count) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_ARR;
    YArray *arr = malloc(sizeof(YArray));
    arr->refcount = 1;
    arr->count = count;
    /* capacity >= count; leave headroom so early pushes don't realloc */
    arr->capacity = count < 8 ? 8 : count;
    /* Copy the pointer array to the heap — the caller's array may be
     * stack-allocated (e.g. from a GCC statement expression). */
    arr->elements = malloc(sizeof(YValue *) * arr->capacity);
    if (count > 0 && elements) {
        memcpy(arr->elements, elements, sizeof(YValue *) * count);
    }
    val->data.arr = arr;
    return val;
}

YValue *y_mk_map(YMapEntry *entries, size_t count) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_MAP;
    YMap *map = malloc(sizeof(YMap));
    map->refcount = 1;
    if (count > 0 && entries) {
        map->entries = malloc(sizeof(YMapEntry) * count);
        /* Dedup keys, last value wins (matches VM semantics). */
        size_t n = 0;
        for (size_t i = 0; i < count; i++) {
            size_t existing = n;
            for (size_t j = 0; j < n; j++) {
                if (strcmp(map->entries[j].key, entries[i].key) == 0) {
                    existing = j;
                    break;
                }
            }
            if (existing < n) {
                /* Duplicate key: last value wins. Free the displaced value
                 * and the incoming (duplicate) key, keep the stored key. */
                y_free(map->entries[existing].value);
                map->entries[existing].value = entries[i].value;
            } else {
                /* Copy the key so the map owns it uniformly (callers pass
                 * string literals; y_free will free() every key). */
                map->entries[n].key = strdup(entries[i].key);
                map->entries[n].value = entries[i].value;
                n++;
            }
        }
        map->count = n;
    } else {
        map->entries = NULL;
        map->count = 0;
    }
    val->data.map = map;
    return val;
}

YValue *y_mk_func(YFuncPtr fn, size_t arity, YScope *closure) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_FUNC;
    YFunc *f = malloc(sizeof(YFunc));
    f->fn = fn;
    f->arity = arity;
    f->closure = closure ? y_scope_retain(closure) : NULL;
    val->data.func = f;
    return val;
}

/* ── Scope operations ───────────────────────────────────────────────────── */

void y_scope_init(YScope *scope, YScope *parent) {
    scope->entries = NULL;
    scope->parent = parent;
    scope->refcount = 1;
}

YScope *y_scope_retain(YScope *scope) {
    if (scope) scope->refcount++;
    return scope;
}

void y_scope_release(YScope *scope) {
    if (!scope) return;
    if (--scope->refcount > 0) return;
    if (scope->refcount < 0) return; /* cycle guard: already being freed */
    scope->refcount = -1;            /* mark as being freed */
    /* Detach entries BEFORE freeing them so any recursive y_scope_release
     * triggered by a closure that references this scope sees an empty scope
     * and the cycle guard above prevents a double-free. */
    YScopeEntry *e = scope->entries;
    scope->entries = NULL;
    while (e) {
        YScopeEntry *next = e->next;
        free(e->name);
        y_free(e->value);
        free(e);
        e = next;
    }
    /* parent is not owned by child scope */
    free(scope);
}

YValue *y_scope_get(YScope *scope, const char *name) {
    for (YScope *s = scope; s; s = s->parent) {
        for (YScopeEntry *e = s->entries; e; e = e->next) {
            if (strcmp(e->name, name) == 0) return e->value;
        }
    }
    fprintf(stderr, "runtime error: undefined variable '%s'\n", name);
    exit(1);
}

/* Take ownership of a value from scope (transfers ownership, leaves a null
 * placeholder so y_scope_set can still find and update the binding in the
 * correct scope). Returns NULL if not found. Use for reassignment patterns
 * like arr = push(arr, x) to avoid COW copies. */
YValue *y_scope_take(YScope *scope, const char *name) {
    for (YScope *s = scope; s; s = s->parent) {
        for (YScopeEntry *e = s->entries; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                YValue *val = e->value;
                e->value = y_mk_null(); /* placeholder keeps the binding alive */
                return val;
            }
        }
    }
    return NULL;
}

void y_scope_set(YScope *scope, const char *name, YValue *value) {
    /* Walk up the scope chain to find an existing binding to update */
    for (YScope *s = scope; s; s = s->parent) {
        for (YScopeEntry *e = s->entries; e; e = e->next) {
            if (strcmp(e->name, name) == 0) {
                y_free(e->value);
                e->value = value;
                return;
            }
        }
    }
    /* New binding in current scope */
    YScopeEntry *e = malloc(sizeof(YScopeEntry));
    e->name = strdup(name);
    e->value = value;
    e->next = scope->entries;
    scope->entries = e;
}

/* Set a binding in the CURRENT scope only (never walks up the chain).
 * Used for 'self' so a nested function's self doesn't clobber the parent's. */
void y_scope_set_local(YScope *scope, const char *name, YValue *value) {
    for (YScopeEntry *e = scope->entries; e; e = e->next) {
        if (strcmp(e->name, name) == 0) {
            y_free(e->value);
            e->value = value;
            return;
        }
    }
    YScopeEntry *e = malloc(sizeof(YScopeEntry));
    e->name = strdup(name);
    e->value = value;
    e->next = scope->entries;
    scope->entries = e;
}

/* ── Aliasing model ─────────────────────────────────────────────────────
 * Arrays and maps are REFERENCE values: a clone shares the underlying
 * YArray/YMap (refcount++), and the mutating builtins (push, map_set,
 * arr_set) mutate that shared object in place. This is exactly what the
 * native backend does (`y_arr_push` grows a shared buffer and returns the
 * same pointer), so all three engines — VM, compiled C, native — agree.
 *
 * The previous copy-on-write behaviour made every `push(st.field, x)` on a
 * record field deep-copy the whole array (the record still holds a
 * reference, so the refcount is always >= 2). The compiler threads its
 * emitter state that way, which turned every emit into an O(n) copy and the
 * whole compile into O(n^2) — the reason the bootstrap took ~20 minutes. */

static void y_map_cow(YValue *map) {
    (void)map; /* reference semantics: mutate the shared map in place */
}

/* ── Value operations ───────────────────────────────────────────────────── */

YValue *y_clone(YValue *val) {
    if (!val) return y_mk_null();
    switch (val->type) {
    case Y_LONG: return y_mk_long(val->data.l);
    case Y_FLOAT: return y_mk_float(val->data.f);
    case Y_BOOL: return y_mk_bool(val->data.b);
    case Y_STR: return y_mk_str(val->data.s);
    case Y_NULL: return y_mk_null();
    case Y_ARR: {
        /* Copy-on-write: share the underlying array, increment refcount */
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_ARR;
        v->data.arr = val->data.arr;
        v->data.arr->refcount++;
        return v;
    }
    case Y_MAP: {
        /* Copy-on-write: share the underlying map, increment refcount */
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_MAP;
        v->data.map = val->data.map;
        v->data.map->refcount++;
        return v;
    }
    case Y_FUNC: {
        /* Functions are shared, not deep-cloned */
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_FUNC;
        YFunc *f = malloc(sizeof(YFunc));
        f->fn = val->data.func->fn;
        f->arity = val->data.func->arity;
        f->closure = y_scope_retain(val->data.func->closure);
        v->data.func = f;
        return v;
    }
    }
    return y_mk_null();
}

void y_free(YValue *val) {
    if (!val) return;
    switch (val->type) {
    case Y_STR: free(val->data.s); break;
    case Y_ARR:
        if (--val->data.arr->refcount == 0) {
            for (size_t i = 0; i < val->data.arr->count; i++)
                y_free(val->data.arr->elements[i]);
            free(val->data.arr->elements);
            free(val->data.arr);
        }
        break;
    case Y_MAP:
        if (--val->data.map->refcount == 0) {
            for (size_t i = 0; i < val->data.map->count; i++) {
                free(val->data.map->entries[i].key);
                y_free(val->data.map->entries[i].value);
            }
            free(val->data.map->entries);
            free(val->data.map);
        }
        break;
    case Y_FUNC:
        y_scope_release(val->data.func->closure);
        free(val->data.func);
        break;
    default: break;
    }
    free(val);
}

static void y_to_buf(YValue *val, char *buf, size_t sz) {
    if (sz <= 1) return;
    switch (val->type) {
    case Y_LONG: snprintf(buf, sz, "%ld", val->data.l); break;
    case Y_FLOAT: snprintf(buf, sz, "%f", val->data.f); break;
    case Y_BOOL: snprintf(buf, sz, "%s", val->data.b ? "true" : "false"); break;
    case Y_STR: snprintf(buf, sz, "%s", val->data.s); break;
    case Y_NULL: snprintf(buf, sz, "null"); break;
    case Y_ARR: {
        snprintf(buf, sz, "[");
        for (size_t i = 0; i < val->data.arr->count; i++) {
            size_t len = strlen(buf);
            y_to_buf(val->data.arr->elements[i], buf + len, sz - len);
            if (i + 1 < val->data.arr->count)
                strncat(buf, ", ", sz - strlen(buf) - 1);
        }
        strncat(buf, "]", sz - strlen(buf) - 1);
        break;
    }
    case Y_MAP: {
        snprintf(buf, sz, "{");
        for (size_t i = 0; i < val->data.map->count; i++) {
            strncat(buf, val->data.map->entries[i].key,
                    sz - strlen(buf) - 1);
            strncat(buf, ": ", sz - strlen(buf) - 1);
            size_t len = strlen(buf);
            y_to_buf(val->data.map->entries[i].value, buf + len, sz - len);
            if (i + 1 < val->data.map->count)
                strncat(buf, ", ", sz - strlen(buf) - 1);
        }
        strncat(buf, "}", sz - strlen(buf) - 1);
        break;
    }
    case Y_FUNC: snprintf(buf, sz, "<function>"); break;
    }
}

char *y_to_str(YValue *val) {
    /* Strings are returned as a fresh copy (caller frees) so arbitrarily long
     * strings survive — the old fixed 4096-byte buffer silently truncated
     * long elements in join()/tostring(), corrupting source-to-source tools. */
    if (val && val->type == Y_STR)
        return strdup(val->data.s);
    char *buf = malloc(4096);
    buf[0] = '\0';
    y_to_buf(val, buf, 4096);
    return buf;
}

void y_print(YValue *val) {
    char *s = y_to_str(val);
    printf("%s\n", s);
    free(s);
}

bool y_equals(YValue *a, YValue *b) {
    if (!a || !b) return a == b;
    if (a == b) return true;
    if (a->type != b->type) return false;
    switch (a->type) {
    case Y_LONG: return a->data.l == b->data.l;
    case Y_FLOAT: return a->data.f == b->data.f;
    case Y_BOOL: return a->data.b == b->data.b;
    case Y_STR: return strcmp(a->data.s, b->data.s) == 0;
    case Y_NULL: return true;
    case Y_ARR: {
        if (a->data.arr->count != b->data.arr->count) return false;
        for (size_t i = 0; i < a->data.arr->count; i++)
            if (!y_equals(a->data.arr->elements[i], b->data.arr->elements[i]))
                return false;
        return true;
    }
    case Y_MAP: {
        if (a->data.map->count != b->data.map->count) return false;
        for (size_t i = 0; i < a->data.map->count; i++) {
            YValue *bv = y_map_get(b, a->data.map->entries[i].key);
            if (!bv || !y_equals(a->data.map->entries[i].value, bv))
                return false;
        }
        return true;
    }
    case Y_FUNC: return a->data.func == b->data.func;
    }
    return false;
}

/* ── Arithmetic / logic ─────────────────────────────────────────────────── */

#define NUMERIC_BINOP(name, op)                                                \
    YValue *name(YValue *a, YValue *b) {                                      \
        YValue *_res;                                                         \
        if (a->type == Y_LONG && b->type == Y_LONG)                           \
            /* Wrap through unsigned: signed overflow is UB (see vm.c). */    \
            _res = y_mk_long((long)((unsigned long)a->data.l op(unsigned long) \
                                        b->data.l));                          \
        else {                                                                \
            double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;    \
            double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;    \
            _res = y_mk_float(av op bv);                                      \
        }                                                                     \
        y_free(a); y_free(b);                                                 \
        return _res;                                                          \
    }

NUMERIC_BINOP(y_sub, -)
NUMERIC_BINOP(y_mul, *)

YValue *y_add(YValue *a, YValue *b) {
    /* Arrays win over strings: `arr + arr` concatenates, `arr + x` appends
     * and `x + arr` prepends, always producing a NEW array (the operands
     * are untouched -- the explicit-copy counterpart of in-place `push`). */
    if (a->type == Y_ARR || b->type == Y_ARR) {
        size_t ln = a->type == Y_ARR ? a->data.arr->count : 1;
        size_t rn = b->type == Y_ARR ? b->data.arr->count : 1;
        YValue **elems = malloc(sizeof(YValue *) * (ln + rn ? ln + rn : 1));
        size_t k = 0;
        if (a->type == Y_ARR)
            for (size_t i = 0; i < ln; i++) elems[k++] = y_clone(a->data.arr->elements[i]);
        else
            elems[k++] = y_clone(a);
        if (b->type == Y_ARR)
            for (size_t i = 0; i < rn; i++) elems[k++] = y_clone(b->data.arr->elements[i]);
        else
            elems[k++] = y_clone(b);
        YValue *v = y_mk_arr(elems, ln + rn);
        free(elems);
        y_free(a); y_free(b);
        return v;
    }
    /* String concatenation if either side is a string */
    if (a->type == Y_STR || b->type == Y_STR) {
        char *as = a->type == Y_STR ? a->data.s : y_to_str(a);
        char *bs = b->type == Y_STR ? b->data.s : y_to_str(b);
        size_t len = strlen(as) + strlen(bs) + 1;
        char *result = malloc(len);
        strcpy(result, as);
        strcat(result, bs);
        if (a->type != Y_STR) free(as);
        if (b->type != Y_STR) free(bs);
        y_free(a); y_free(b); /* take ownership of cloned operands */
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_STR;
        v->data.s = result;
        return v;
    }
    if (a->type == Y_LONG && b->type == Y_LONG) {
        /* Wrap through unsigned: signed overflow is UB (see vm.c). */
        long r = (long)((unsigned long)a->data.l + (unsigned long)b->data.l);
        y_free(a); y_free(b);
        return y_mk_long(r);
    }
    double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;
    double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;
    y_free(a); y_free(b);
    return y_mk_float(av + bv);
}

YValue *y_div(YValue *a, YValue *b) {
    if (a->type == Y_LONG && b->type == Y_LONG) {
        if (b->data.l == 0) {
            fprintf(stderr, "runtime error: division by zero\n");
            exit(1);
        }
        long r = (a->data.l == LONG_MIN && b->data.l == -1)
                     ? LONG_MIN /* overflows; both other engines wrap */
                     : a->data.l / b->data.l;
        y_free(a); y_free(b);
        return y_mk_long(r);
    }
    double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;
    double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;
    y_free(a); y_free(b);
    return y_mk_float(av / bv);
}

YValue *y_mod(YValue *a, YValue *b) {
    if (a->type != Y_LONG || b->type != Y_LONG) {
        fprintf(stderr, "runtime error: %% requires integer operands\n");
        exit(1);
    }
    if (b->data.l == 0) {
        fprintf(stderr, "runtime error: modulo by zero\n");
        exit(1);
    }
    long r = (a->data.l == LONG_MIN && b->data.l == -1)
                 ? 0 /* mathematically 0, but idiv traps on this pair */
                 : a->data.l % b->data.l;
    y_free(a); y_free(b);
    return y_mk_long(r);
}

#define CMP_BINOP(name, op)                                                    \
    YValue *name(YValue *a, YValue *b) {                                      \
        bool res;                                                             \
        if (a->type == Y_STR && b->type == Y_STR)                             \
            /* Lexicographic, matching the VM. */                             \
            res = strcmp(a->data.s, b->data.s) op 0;                          \
        else if (a->type == Y_LONG && b->type == Y_LONG)                      \
            res = a->data.l op b->data.l;                                     \
        else {                                                                \
            double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;    \
            double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;    \
            res = av op bv;                                                   \
        }                                                                     \
        y_free(a); y_free(b);                                                 \
        return y_mk_bool(res);                                                \
    }

CMP_BINOP(y_lt, <)
CMP_BINOP(y_gt, >)
CMP_BINOP(y_lte, <=)
CMP_BINOP(y_gte, >=)

YValue *y_eq(YValue *a, YValue *b) { bool r = y_equals(a, b); y_free(a); y_free(b); return y_mk_bool(r); }
YValue *y_neq(YValue *a, YValue *b) { bool r = !y_equals(a, b); y_free(a); y_free(b); return y_mk_bool(r); }

YValue *y_and(YValue *a, YValue *b) {
    if (a->type != Y_BOOL || b->type != Y_BOOL) {
        fprintf(stderr, "runtime error: && requires boolean operands\n");
        exit(1);
    }
    bool r = a->data.b && b->data.b;
    y_free(a); y_free(b);
    return y_mk_bool(r);
}
YValue *y_or(YValue *a, YValue *b) {
    if (a->type != Y_BOOL || b->type != Y_BOOL) {
        fprintf(stderr, "runtime error: || requires boolean operands\n");
        exit(1);
    }
    bool r = a->data.b || b->data.b;
    y_free(a); y_free(b);
    return y_mk_bool(r);
}

YValue *y_neg(YValue *a) {
    /* Negate through unsigned: -LONG_MIN is signed-overflow UB. */
    if (a->type == Y_LONG) { long r = (long)(0UL - (unsigned long)a->data.l); y_free(a); return y_mk_long(r); }
    double r = -a->data.f; y_free(a); return y_mk_float(r);
}

/* ── Array / map operations ─────────────────────────────────────────────── */

YValue *y_arr_index(YValue *arr, YValue *idx) {
    if (arr->type != Y_ARR) {
        fprintf(stderr, "runtime error: indexing a non-array\n");
        exit(1);
    }
    long i = idx->data.l;
    long count = (long)arr->data.arr->count;
    if (count == 0) {
        fprintf(stderr, "runtime error: index out of bounds (empty array)\n");
        exit(1);
    }
    i = ((i % count) + count) % count;
    YValue *elem = y_clone(arr->data.arr->elements[i]);
    y_free(idx);
    y_free(arr); /* take ownership of the (cloned) array argument */
    return elem;
}

/* Index an array WITHOUT cloning the array itself. The caller passes a
 * borrowed (non-owned) array reference; only the element is cloned.
 * This avoids the catastrophic O(n) clone-per-index when code does
 * `arr[i]` in a tight loop (e.g. the parser indexing the token array). */
YValue *y_arr_index_borrow(YValue *arr, YValue *idx) {
    if (arr->type != Y_ARR) {
        fprintf(stderr, "runtime error: indexing a non-array\n");
        exit(1);
    }
    long i = idx->data.l;
    long count = (long)arr->data.arr->count;
    if (count == 0) {
        fprintf(stderr, "runtime error: index out of bounds (empty array)\n");
        exit(1);
    }
    i = ((i % count) + count) % count;
    YValue *elem = y_clone(arr->data.arr->elements[i]);
    y_free(idx); /* owns idx, but NOT the borrowed array */
    return elem;
}

YValue *y_arr_slice(YValue *arr, YValue *start_v, YValue *end_v) {
    if (arr->type != Y_ARR) {
        fprintf(stderr, "runtime error: slicing a non-array\n");
        exit(1);
    }
    long count = (long)arr->data.arr->count;
    long start = start_v->data.l;
    long end = end_v->data.l;

    // Handle LONG_MIN sentinel for "to the end"
    if (end == -9223372036854775807) end = count;

    // Handle negative indices (count from end)
    if (start < 0) start = count + start;
    if (end < 0) end = count + end;

    // Clamp to bounds
    if (start < 0) start = 0;
    if (start > count) start = count;
    if (end < 0) end = 0;
    if (end > count) end = count;

    // Empty slice if start >= end
    if (start >= end) {
        y_free(arr); y_free(start_v); y_free(end_v);
        return y_mk_arr(NULL, 0);
    }

    size_t n = (size_t)(end - start);
    YValue **elems = malloc(sizeof(YValue *) * n);
    for (size_t i = 0; i < n; i++) {
        elems[i] = y_clone(arr->data.arr->elements[start + (long)i]);
    }
    YValue *result = y_mk_arr(elems, n);
    free(elems);
    y_free(arr); y_free(start_v); y_free(end_v);
    return result;
}

YValue *y_map_get(YValue *map, const char *key) {
    if (map->type != Y_MAP) return NULL;
    for (size_t i = 0; i < map->data.map->count; i++) {
        if (strcmp(map->data.map->entries[i].key, key) == 0)
            return map->data.map->entries[i].value;
    }
    return NULL;
}

/* map_set(map, key, value) -> map  — set/overwrite a key, COW-safe, returns
 * the map for chaining. Enables dynamic map-key assignment from Y code. */
YValue *y_builtin_map_set(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 3 || args[0]->type != Y_MAP || args[1]->type != Y_STR)
        return argc >= 1 ? args[0] : y_mk_null();
    YValue *map = args[0];
    const char *key = args[1]->data.s;
    y_map_cow(map);
    YMap *m = map->data.map;
    for (size_t i = 0; i < m->count; i++) {
        if (strcmp(m->entries[i].key, key) == 0) {
            y_free(m->entries[i].value);
            m->entries[i].value = y_clone(args[2]);
            return map;
        }
    }
    m->entries = realloc(m->entries, sizeof(YMapEntry) * (m->count + 1));
    m->entries[m->count].key = strdup(key);
    m->entries[m->count].value = y_clone(args[2]);
    m->count++;
    return map;
}

/* Set a key, taking ownership of `val`. Last write wins, position kept. */
void y_map_put(YValue *map, const char *key, YValue *val) {
    if (map->type != Y_MAP) {
        fprintf(stderr, "runtime error: map target is not a map\n");
        exit(1);
    }
    YMap *m = map->data.map;
    for (size_t i = 0; i < m->count; i++) {
        if (strcmp(m->entries[i].key, key) == 0) {
            y_free(m->entries[i].value);
            m->entries[i].value = val;
            return;
        }
    }
    m->entries = realloc(m->entries, sizeof(YMapEntry) * (m->count + 1));
    m->entries[m->count].key = strdup(key);
    m->entries[m->count].value = val;
    m->count++;
}

/* `{...src}` — splice src's entries into dst (later keys win). Consumes
 * src, which is a temporary produced by the spread expression. */
void y_map_merge(YValue *dst, YValue *src) {
    if (src->type != Y_MAP) {
        fprintf(stderr, "runtime error: spread source must be a map\n");
        exit(1);
    }
    YMap *s = src->data.map;
    for (size_t i = 0; i < s->count; i++)
        y_map_put(dst, s->entries[i].key, y_clone(s->entries[i].value));
    y_free(src);
}

/* map_get(map, key) -> value|null — read a key from a map (null if absent). */
YValue *y_builtin_map_get(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_MAP || args[1]->type != Y_STR)
        return y_mk_null();
    YValue *v = y_map_get(args[0], args[1]->data.s);
    return v ? y_clone(v) : y_mk_null();
}

/* global_get(name) -> value|null — look up a name in the *enclosing C scope*.
 * Registered with the global scope as its closure, so the Y VM (whose own
 * scope chain is separate Y-maps) can fall back to host builtins/globals.
 * Returns null (not an error) when the name is absent. */
YValue *y_builtin_global_get(YScope *closure, YValue **args, size_t argc) {
    if (argc < 1 || args[0]->type != Y_STR) return y_mk_null();
    const char *name = args[0]->data.s;
    for (YScope *s = closure; s; s = s->parent) {
        for (YScopeEntry *e = s->entries; e; e = e->next) {
            if (strcmp(e->name, name) == 0) return y_clone(e->value);
        }
    }
    return y_mk_null();
}

/* ── Native scope registry for the Y VM ──────────────────────────────────
 * The Y VM needs mutable scopes, but Y's COW semantics make nested-structure
 * mutation unreliable. These builtins manage real C YScopes in a global
 * registry, indexed by integer ID, so the VM can create/define/lookup scopes
 * with correct mutation semantics. */
static YScope **g_vm_scopes = NULL;
static size_t g_vm_scope_count = 0;
static size_t g_vm_scope_cap = 0;

/* scope_new(parent_id) -> long — create a scope, return its ID. parent_id -1 = root. */
YValue *y_builtin_scope_new(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    long parent_id = (argc >= 1 && args[0]->type == Y_LONG) ? args[0]->data.l : -1;
    if (g_vm_scope_count >= g_vm_scope_cap) {
        g_vm_scope_cap = g_vm_scope_cap ? g_vm_scope_cap * 2 : 16;
        g_vm_scopes = realloc(g_vm_scopes, sizeof(YScope *) * g_vm_scope_cap);
    }
    YScope *s = malloc(sizeof(YScope));
    YScope *parent = (parent_id >= 0 && (size_t)parent_id < g_vm_scope_count)
                         ? g_vm_scopes[parent_id] : NULL;
    y_scope_init(s, parent);
    long id = (long)g_vm_scope_count++;
    g_vm_scopes[id] = s;
    return y_mk_long(id);
}

/* scope_def(id, name, val) -> null — define a new binding in scope id. */
YValue *y_builtin_scope_def(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 3 || args[0]->type != Y_LONG || args[1]->type != Y_STR) return y_mk_null();
    long id = args[0]->data.l;
    if (id < 0 || (size_t)id >= g_vm_scope_count) return y_mk_null();
    y_scope_set(g_vm_scopes[id], args[1]->data.s, y_clone(args[2]));
    return y_mk_null();
}

/* scope_find(id, name) -> long — find scope id defining name (walking parents), or -1. */
YValue *y_builtin_scope_find(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_LONG || args[1]->type != Y_STR) return y_mk_long(-1);
    long id = args[0]->data.l;
    const char *name = args[1]->data.s;
    while (id >= 0 && (size_t)id < g_vm_scope_count) {
        YScope *s = g_vm_scopes[id];
        for (YScopeEntry *e = s->entries; e; e = e->next) {
            if (strcmp(e->name, name) == 0) return y_mk_long(id);
        }
        /* find this scope's parent id */
        long pid = -1;
        for (size_t i = 0; i < g_vm_scope_count; i++) {
            if (g_vm_scopes[i] == s->parent) { pid = (long)i; break; }
        }
        id = pid;
    }
    return y_mk_long(-1);
}

/* scope_get(id, name) -> value|null — get a variable from scope id or its parents.
 * Returns null (not an error) when absent, so the VM can detect undefined vars. */
YValue *y_builtin_scope_get(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_LONG || args[1]->type != Y_STR) return y_mk_null();
    YValue *find_args[2] = { args[0], args[1] };
    YValue *found = y_builtin_scope_find(closure, find_args, 2);
    if (found->data.l < 0) { y_free(found); return y_mk_null(); }
    long sid = found->data.l;
    y_free(found);
    YValue *v = y_scope_get(g_vm_scopes[sid], args[1]->data.s);
    return v ? y_clone(v) : y_mk_null();
}

/* scope_set(id, name, val) -> null — set a variable in the nearest scope defining
 * it (walking parents); if none defines it, define in scope id. */
YValue *y_builtin_scope_set(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 3 || args[0]->type != Y_LONG || args[1]->type != Y_STR) return y_mk_null();
    YValue *find_args[2] = { args[0], args[1] };
    YValue *found = y_builtin_scope_find(closure, find_args, 2);
    long sid = found->data.l;
    y_free(found);
    if (sid < 0) sid = args[0]->data.l;  // not found: define in the given scope
    if (sid < 0 || (size_t)sid >= g_vm_scope_count) return y_mk_null();
    y_scope_set(g_vm_scopes[sid], args[1]->data.s, y_clone(args[2]));
    return y_mk_null();
}

YValue *y_cons(YValue *head, YValue *tail) {
    if (tail->type != Y_ARR) {
        fprintf(stderr, "runtime error: :: requires array on right\n");
        exit(1);
    }
    size_t n = tail->data.arr->count + 1;
    YValue **elems = malloc(sizeof(YValue *) * n);
    elems[0] = y_clone(head);
    for (size_t i = 0; i < tail->data.arr->count; i++)
        elems[i + 1] = y_clone(tail->data.arr->elements[i]);
    YValue *result = y_mk_arr(elems, n);
    free(elems);
    y_free(head); y_free(tail);
    return result;
}

/* ── Function calls ─────────────────────────────────────────────────────── */

YValue *y_call(YValue *callee, YValue **args, size_t argc) {
    if (callee->type != Y_FUNC) {
        fprintf(stderr, "runtime error: calling a non-function\n");
        exit(1);
    }
    return callee->data.func->fn(callee->data.func->closure, args, argc);
}

/* ── Built-in functions ─────────────────────────────────────────────────── */

YValue *y_builtin_print(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc > 0) y_print(args[0]);
    return y_mk_null();
}

YValue *y_builtin_tostring(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc > 0) {
        char *s = y_to_str(args[0]);
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_STR;
        v->data.s = s;
        return v;
    }
    return y_mk_null();
}

YValue *y_builtin_range(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_LONG) {
        fprintf(stderr, "runtime error: range() requires a long argument\n");
        exit(1);
    }
    long n = args[0]->data.l;
    if (n < 0) n = 0;
    YValue **elems = malloc(sizeof(YValue *) * (size_t)n);
    for (long i = 0; i < n; i++) elems[i] = y_mk_long(i);
    return y_mk_arr(elems, (size_t)n);
}

/* typeof: return a string describing the value's type (approximates the
 * VM's VAL_TYPE behaviour closely enough for printing). */
static void y_type_name(YValue *val, char *buf, size_t sz) {
    switch (val->type) {
    case Y_LONG: snprintf(buf, sz, "long"); break;
    case Y_FLOAT: snprintf(buf, sz, "float"); break;
    case Y_BOOL: snprintf(buf, sz, "bool"); break;
    case Y_STR: snprintf(buf, sz, "str"); break;
    case Y_NULL: snprintf(buf, sz, "null"); break;
    case Y_ARR:
        snprintf(buf, sz, "[");
        if (val->data.arr->count > 0) {
            size_t len = strlen(buf);
            y_type_name(val->data.arr->elements[0], buf + len, sz - len);
        }
        strncat(buf, "]", sz - strlen(buf) - 1);
        break;
    case Y_MAP:
        snprintf(buf, sz, "{");
        for (size_t i = 0; i < val->data.map->count; i++) {
            strncat(buf, val->data.map->entries[i].key, sz - strlen(buf) - 1);
            strncat(buf, ": ", sz - strlen(buf) - 1);
            size_t len = strlen(buf);
            y_type_name(val->data.map->entries[i].value, buf + len, sz - len);
            if (i + 1 < val->data.map->count)
                strncat(buf, ", ", sz - strlen(buf) - 1);
        }
        strncat(buf, "}", sz - strlen(buf) - 1);
        break;
    case Y_FUNC: {
        snprintf(buf, sz, "(");
        for (size_t i = 0; i < val->data.func->arity; i++) {
            strncat(buf, "<inferred>", sz - strlen(buf) - 1);
            if (i + 1 < val->data.func->arity)
                strncat(buf, ", ", sz - strlen(buf) - 1);
        }
        strncat(buf, ")-><inferred>", sz - strlen(buf) - 1);
        break;
    }
    }
}

YValue *y_builtin_typeof(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1) return y_mk_null();
    char buf[512];
    y_type_name(args[0], buf, sizeof(buf));
    YValue *v = malloc(sizeof(YValue));
    v->type = Y_STR;
    v->data.s = strdup(buf);
    return v;
}

/* readline() -> str | null on EOF
 * EOF is NOT latched (see lib.c): clearerr() leaves the stream readable so a
 * later call picks up new input, which is how the native backend's raw
 * read(2) on fd 0 already behaves. */
YValue *y_builtin_readline(YScope *closure, YValue **args, size_t argc) {
    (void)closure; (void)args; (void)argc;
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        clearerr(stdin);
        return y_mk_null();
    }
    if (n > 0 && line[n - 1] == '\n') line[--n] = '\0';
    YValue *v = malloc(sizeof(YValue));
    v->type = Y_STR;
    v->data.s = line;
    return v;
}

/* puts(s) — print without a trailing newline (and flush, for interactive use) */
YValue *y_builtin_puts(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc > 0) {
        char *s = y_to_str(args[0]);
        fputs(s, stdout);
        fflush(stdout);
        free(s);
    }
    return y_mk_null();
}

/* eputs(s) — raw output to stderr, no prefix, no newline. Diagnostics go
 * here so they never mix into a program's stdout (or into `-S` output). */
YValue *y_builtin_eputs(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc > 0) {
        char *s = y_to_str(args[0]);
        fputs(s, stderr);
        fflush(stderr);
        free(s);
    }
    return y_mk_null();
}

/* sleep(ms) -> null: suspend the caller for ms milliseconds. */
YValue *y_builtin_sleep(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    struct timespec req;
    long ms = 0;
    if (argc > 0 && args[0]->type == Y_LONG && args[0]->data.l > 0)
        ms = args[0]->data.l;
    req.tv_sec = (time_t)(ms / 1000);
    req.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&req, &req) != 0 && errno == EINTR) {
    }
    return y_mk_null();
}

/* clock_us() -> long: monotonic microseconds (only differences are
 * meaningful — the origin is arbitrary). */
YValue *y_builtin_clock_us(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    (void)args;
    (void)argc;
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return y_mk_long(0);
    return y_mk_long((long)ts.tv_sec * 1000000L + (long)ts.tv_nsec / 1000L);
}

/* heap_used() -> long: bytes of heap currently handed out. The native
 * backend reports its arena break, so across engines only deltas between
 * two samples are comparable. */
YValue *y_builtin_heap_used(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    (void)args;
    (void)argc;
    struct mallinfo2 mi = mallinfo2();
    return y_mk_long((long)mi.uordblks);
}

/* exit(code): terminate the process (allows drivers to propagate failures). */
YValue *y_builtin_exit(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    int c = 0;
    if (argc > 0 && args[0]->type == Y_LONG) c = (int)(args[0]->data.l & 0xff);
    exit(c);
    return y_mk_null();
}

/* split(s, delim) -> [str] */
YValue *y_builtin_split(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_STR)
        return y_mk_arr(NULL, 0);
    const char *s = args[0]->data.s;
    const char *delim = args[1]->data.s;
    size_t dlen = strlen(delim);
    if (dlen == 0) return y_mk_arr(NULL, 0);
    /* Count tokens first */
    size_t count = 0;
    const char *p = s;
    while (*p) {
        count++;
        const char *next = strstr(p, delim);
        p = next ? next + dlen : p + strlen(p);
    }
    if (count == 0) return y_mk_arr(NULL, 0);
    YValue **elems = malloc(sizeof(YValue *) * count);
    size_t i = 0;
    p = s;
    while (*p) {
        const char *next = strstr(p, delim);
        size_t len = next ? (size_t)(next - p) : strlen(p);
        elems[i++] = y_mk_str_n(p, len);
        p = next ? next + dlen : p + strlen(p);
    }
    YValue *arr = y_mk_arr(elems, count);
    free(elems);
    return arr;
}

/* len(x) -> long  (string length or array count) */
YValue *y_builtin_len(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1) return y_mk_long(0);
    switch (args[0]->type) {
    case Y_STR: return y_mk_long((long)strlen(args[0]->data.s));
    case Y_ARR: return y_mk_long((long)args[0]->data.arr->count);
    default: return y_mk_long(0);
    }
}

/* trim(s) -> str  (strip leading/trailing whitespace) */
YValue *y_builtin_trim(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR) return y_mk_str("");
    const char *s = args[0]->data.s;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    size_t len = strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' ||
                       s[len-1] == '\n' || s[len-1] == '\r'))
        len--;
    return y_mk_str_n(s, len);
}

/* exec(cmd) -> long  (system() call, returns exit code)
 *
 * SECURITY: This passes `cmd` verbatim to /bin/sh -c via system(). Any
 * shell metacharacters in the string (;, |, &&, $(), backticks, etc.) are
 * interpreted by the shell. This is intentional — exec() is the escape hatch
 * that lets y programs drive the host system (see examples/shell.y). Do NOT
 * pass untrusted input into exec() without sanitizing; treat it like C's
 * system(). There is deliberately no sandboxing. */
YValue *y_builtin_exec(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR) return y_mk_long(-1);
    int ret = system(args[0]->data.s);
    return y_mk_long(WIFEXITED(ret) ? WEXITSTATUS(ret) : -1);
}

/* argv() -> [str]  (command-line arguments) */
static int g_argc = 0;
static char **g_argv = NULL;

void y_set_argv(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

YValue *y_builtin_argv(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    (void)args;
    (void)argc;
    YValue **elements = malloc(sizeof(YValue *) * (g_argc > 0 ? g_argc : 1));
    for (int i = 0; i < g_argc; i++) {
        elements[i] = y_mk_str(g_argv[i]);
    }
    YValue *arr = y_mk_arr(elements, g_argc);
    free(elements);
    return arr;
}

/* tonum(s) -> long  (parse integer from string, 0 on failure) */
YValue *y_builtin_tonum(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1) return y_mk_long(0);
    if (args[0]->type == Y_LONG) return y_mk_long(args[0]->data.l);
    if (args[0]->type == Y_FLOAT) return y_mk_long((long)args[0]->data.f);
    if (args[0]->type != Y_STR) return y_mk_long(0);
    char *end;
    long v = strtol(args[0]->data.s, &end, 10);
    if (end == args[0]->data.s) return y_mk_long(0);
    return y_mk_long(v);
}

/* join(arr, delim) -> str */
YValue *y_builtin_join(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_ARR || args[1]->type != Y_STR)
        return y_mk_str("");
    YArray *arr = args[0]->data.arr;
    const char *delim = args[1]->data.s;
    size_t total = 0;
    char **parts = malloc(sizeof(char *) * (arr->count > 0 ? arr->count : 1));
    for (size_t i = 0; i < arr->count; i++) {
        parts[i] = y_to_str(arr->elements[i]);
        total += strlen(parts[i]);
    }
    total += strlen(delim) * (arr->count > 0 ? arr->count - 1 : 0) + 1;
    char *result = malloc(total);
    result[0] = '\0';
    for (size_t i = 0; i < arr->count; i++) {
        if (i > 0) strcat(result, delim);
        strcat(result, parts[i]);
        free(parts[i]);
    }
    free(parts);
    YValue *v = malloc(sizeof(YValue));
    v->type = Y_STR;
    v->data.s = result;
    return v;
}

/* push(arr, val) -> arr  (append, returns new array) */
YValue *y_builtin_push(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_ARR) return y_mk_arr(NULL, 0);
    /* Reference semantics: grow the shared array in place (realloc),
     * O(1) amortized — never copy. Matches the native `y_arr_push`. */
    YArray *a = args[0]->data.arr;
    /* geometric growth → O(1) amortized push (no realloc per element) */
    if (a->count + 1 > a->capacity) {
        size_t newcap = a->capacity < 8 ? 8 : a->capacity * 2;
        a->elements = realloc(a->elements, sizeof(YValue *) * newcap);
        a->capacity = newcap;
    }
    a->elements[a->count] = args[1]; /* take ownership of the already-cloned arg */
    a->count++;
    args[1] = NULL; /* prevent double-free by call site */
    YValue *result = args[0];
    args[0] = NULL; /* transfer ownership to caller */
    return result;
}

/* substr(s, start, len) -> str */
YValue *y_builtin_substr(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 3 || args[0]->type != Y_STR) return y_mk_str("");
    const char *s = args[0]->data.s;
    long slen = (long)strlen(s);
    long start = args[1]->data.l;
    long count = args[2]->data.l;
    if (start < 0) start = 0;
    if (start >= slen) return y_mk_str("");
    if (count < 0 || start + count > slen) count = slen - start;
    return y_mk_str_n(s + start, (size_t)count);
}

/* read_file(path) -> str | null on error */
YValue *y_builtin_read_file(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR) return y_mk_null();
    FILE *f = fopen(args[0]->data.s, "rb");
    if (!f) return y_mk_null();
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return y_mk_null(); }
    char *buf = malloc((size_t)sz + 1);
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    YValue *v = malloc(sizeof(YValue));
    v->type = Y_STR;
    v->data.s = buf;
    return v;
}

/* some(v) -> v — options are value-or-null on this toolchain (no wrapper):
 * some is the identity (cloned for ownership safety). */
YValue *y_builtin_some(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || !args[0]) return y_mk_null();
    return y_clone(args[0]);
}

/* is_some(v) -> bool — true unless v is null. */
YValue *y_builtin_is_some(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || !args[0]) return y_mk_bool(false);
    return y_mk_bool(args[0]->type != Y_NULL);
}

/* unwrap(v) -> v — identity (cloned); LOUD failure on null (programmer
 * error: forgot the `== null` check). Matches native gen_unwrap (trap). */
YValue *y_builtin_unwrap(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || !args[0] || args[0]->type == Y_NULL) {
        fprintf(stderr, "runtime error: unwrap of null\n");
        exit(1);
    }
    return y_clone(args[0]);
}

/* write_file(path, content) -> bool (success).
 * NOTE: C strings cannot carry NUL bytes, so this writes strlen(content)
 * bytes (text only). For binary data (ELF bytes with NULs), use
 * write_bytes(path, arr, mode) below. */
YValue *y_builtin_write_file(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_STR)
        return y_mk_bool(false);
    FILE *f = fopen(args[0]->data.s, "wb");
    if (!f) return y_mk_bool(false);
    size_t n = strlen(args[1]->data.s);
    size_t wr = fwrite(args[1]->data.s, 1, n, f);
    fclose(f);
    return y_mk_bool(wr == n);
}

/* write_bytes(path, bytes, mode) -> bool: write a byte array to a file
 * (binary-safe: NULs included) and chmod it to mode (use -1 to skip).
 * Mirrors tinycc's tcc_write_elf_file output step (open/write/chmod), minus
 * the buffered FILE layer — one open(2)+write(2)+chmod pass. Y strings
 * cannot carry NUL, so bytes arrive as [long] (0-255), like elf.y output. */
YValue *y_builtin_write_bytes(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_ARR)
        return y_mk_bool(false);
    long mode = (argc >= 3 && args[2]->type == Y_LONG) ? args[2]->data.l : -1;
    YArray *a = args[1]->data.arr;
    char *buf = malloc(a->count ? a->count : 1);
    if (!buf) return y_mk_bool(false);
    for (size_t i = 0; i < a->count; i++) {
        YValue *e = a->elements[i];
        buf[i] = (char)(e && e->type == Y_LONG ? (e->data.l & 0xFF) : 0);
    }
    FILE *f = fopen(args[0]->data.s, "wb");
    if (!f) { free(buf); return y_mk_bool(false); }
    size_t wr = fwrite(buf, 1, a->count, f);
    fclose(f);
    free(buf);
    if (wr != a->count) return y_mk_bool(false);
    if (mode >= 0) {
        if (chmod(args[0]->data.s, (mode_t)mode) != 0) return y_mk_bool(false);
    }
    return y_mk_bool(true);
}

/* ord(s) -> long  (code point of first char, -1 if empty) */
YValue *y_builtin_ord(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR || args[0]->data.s[0] == '\0')
        return y_mk_long(-1);
    return y_mk_long((long)(unsigned char)args[0]->data.s[0]);
}

/* chr(n) -> str  (single-byte string from code point) */
YValue *y_builtin_chr(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1) return y_mk_str("");
    char buf[2] = { (char)(args[0]->data.l & 0xFF), '\0' };
    return y_mk_str_n(buf, 1);
}

/* clear_eof() -> null  (see lib.c: clear the EOF condition so a later
 * readline() reads again; examples/ysh.y uses it to keep its REPL alive
 * after draining stdin for a multi-line body) */
YValue *y_builtin_clear_eof(YScope *closure, YValue **args, size_t argc) {
    (void)closure; (void)args; (void)argc;
    clearerr(stdin);
    return y_mk_null();
}

/* bytes(s) -> [byte]  (raw bytes of a string; a plain long array here —
 * only the native backend packs them one byte per element) */
YValue *y_builtin_bytes(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR) return y_mk_arr(NULL, 0);
    const char *s = args[0]->data.s;
    size_t n = strlen(s);
    YValue **elems = malloc(sizeof(YValue *) * (n > 0 ? n : 1));
    for (size_t i = 0; i < n; i++) elems[i] = y_mk_long((unsigned char)s[i]);
    YValue *arr = y_mk_arr(elems, n);
    free(elems);
    return arr;
}

/* from_bytes(b) -> str  (inverse of bytes()) */
YValue *y_builtin_from_bytes(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_ARR) return y_mk_str("");
    size_t n = args[0]->data.arr->count;
    char *buf = malloc(n + 1);
    for (size_t i = 0; i < n; i++) {
        YValue *e = args[0]->data.arr->elements[i];
        buf[i] = (char)((e && e->type == Y_LONG) ? (e->data.l & 0xFF) : 0);
    }
    buf[n] = '\0';
    YValue *r = y_mk_str_n(buf, n);
    free(buf);
    return r;
}

/* ord_at(s, i) -> long  (byte value at index i, O(1), no allocation —
 * unlike substr(s,i,1)+ord which allocates a string per char) */
YValue *y_builtin_ord_at(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_LONG)
        return y_mk_long(0);
    const char *s = args[0]->data.s;
    long i = args[1]->data.l;
    long n = (long)strlen(s);
    if (i < 0 || i >= n) return y_mk_long(0);
    return y_mk_long((long)(unsigned char)s[i]);
}

/* bytes_to_str(arr) -> str  (build a string from an array of byte longs;
 * O(n) single allocation — used to materialize embedded binary data) */
YValue *y_builtin_bytes_to_str(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_ARR) return y_mk_str("");
    YArray *a = args[0]->data.arr;
    char *buf = malloc(a->count + 1);
    for (size_t i = 0; i < a->count; i++) {
        YValue *e = a->elements[i];
        buf[i] = (char)(e && e->type == Y_LONG ? (e->data.l & 0xFF) : 0);
    }
    buf[a->count] = '\0';
    YValue *v = malloc(sizeof(YValue));
    v->type = Y_STR;
    v->data.s = buf;
    return v;
}

/* index_of(s, sub) -> long  (first index of sub in s, -1 if not found) */
YValue *y_builtin_index_of(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_STR)
        return y_mk_long(-1);
    const char *hit = strstr(args[0]->data.s, args[1]->data.s);
    if (!hit) return y_mk_long(-1);
    return y_mk_long((long)(hit - args[0]->data.s));
}

/* arr_index_of(arr, val) -> long  (first index where arr[i] == val, or -1) */
YValue *y_builtin_arr_index_of(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_ARR)
        return y_mk_long(-1);
    YArray *arr = args[0]->data.arr;
    for (size_t i = 0; i < arr->count; i++) {
        if (y_equals(arr->elements[i], args[1]))
            return y_mk_long((long)i);
    }
    return y_mk_long(-1);
}

/* last_index_of(s, sub) -> long  (last index of sub in s, -1 if not found) */
YValue *y_builtin_last_index_of(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_STR || args[1]->type != Y_STR)
        return y_mk_long(-1);
    const char *hay = args[0]->data.s;
    const char *needle = args[1]->data.s;
    size_t nlen = strlen(needle);
    if (nlen == 0) return y_mk_long((long)strlen(hay));
    const char *last = NULL;
    for (const char *p = hay; (p = strstr(p, needle)) != NULL; p++)
        last = p;
    if (!last) return y_mk_long(-1);
    return y_mk_long((long)(last - hay));
}

/* getenv(name) -> str|null — read an environment variable */
YValue *y_builtin_getenv(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_STR)
        return y_mk_null();
    const char *val = getenv(args[0]->data.s);
    if (!val) return y_mk_null();
    return y_mk_str(val);
}

/* arr_set(arr, idx, val) — mutate an array element, or a map entry when
 * the target is a map with a string key (`s.f = v` and `m["k"] = v`). */
void y_arr_set(YValue *arr, YValue *idx, YValue *val) {
    if (arr->type == Y_MAP) {
        if (idx->type != Y_STR) {
            fprintf(stderr, "runtime error: map key must be a string\n");
            exit(1);
        }
        YMap *m = arr->data.map;
        for (size_t i = 0; i < m->count; i++) {
            if (strcmp(m->entries[i].key, idx->data.s) == 0) {
                y_free(m->entries[i].value);
                m->entries[i].value = val;
                return;
            }
        }
        m->entries = realloc(m->entries, sizeof(YMapEntry) * (m->count + 1));
        m->entries[m->count].key = strdup(idx->data.s);
        m->entries[m->count].value = val;
        m->count++;
        return;
    }
    if (arr->type != Y_ARR) {
        fprintf(stderr, "runtime error: arr_set target is not an array\n");
        exit(1);
    }
    long i = idx->data.l;
    long count = (long)arr->data.arr->count;
    if (count == 0) {
        fprintf(stderr, "runtime error: array index out of bounds (empty)\n");
        exit(1);
    }
    i = (i % count + count) % count; /* normalize negative indices */
    y_free(arr->data.arr->elements[i]);
    arr->data.arr->elements[i] = val;
}

/* ── String escaping ────────────────────────────────────────────────────── */

char *y_escape_c_string(const char *s, size_t len) {
    /* Worst case: every char becomes \NNN (4 chars) */
    char *out = malloc(len * 4 + 1);
    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '\\': out[j++] = '\\'; out[j++] = '\\'; break;
        case '"': out[j++] = '\\'; out[j++] = '"'; break;
        case '\n': out[j++] = '\\'; out[j++] = 'n'; break;
        case '\t': out[j++] = '\\'; out[j++] = 't'; break;
        case '\r': out[j++] = '\\'; out[j++] = 'r'; break;
        default:
            if (c < 32 || c > 126) {
                j += sprintf(out + j, "\\%03o", c);
            } else {
                out[j++] = (char)c;
            }
        }
    }
    out[j] = '\0';
    return out;
}

/* ── TCP networking builtins ─────────────────────────────────────────────
 * A deliberately tiny socket API so Y programs can implement their own
 * HTTP server. File descriptors are passed around as longs.
 *   tcp_listen(port)            -> long listen fd, or -1
 *   tcp_accept(listen_fd)       -> long client fd, or -1
 *   tcp_read(fd, max)           -> str of up to max bytes ("" on EOF/error)
 *   tcp_write(fd, data)         -> long bytes written, or -1
 *   tcp_close(fd)               -> null
 */

YValue *y_builtin_tcp_listen(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    ignore_sigpipe_once();
    if (argc < 1 || args[0]->type != Y_LONG) return y_mk_long(-1);
    int port = (int)args[0]->data.l;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return y_mk_long(-1);

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return y_mk_long(-1);
    }
    if (listen(fd, 16) < 0) {
        close(fd);
        return y_mk_long(-1);
    }
    return y_mk_long(fd);
}

YValue *y_builtin_tcp_accept(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 1 || args[0]->type != Y_LONG) return y_mk_long(-1);
    int lfd = (int)args[0]->data.l;
    int cfd = accept(lfd, NULL, NULL);
    if (cfd >= 0) {
        // Set a receive timeout to prevent slowloris DoS (client sends
        // headers with huge Content-Length then trickles/no body).
        struct timeval tv;
        tv.tv_sec = 10;
        tv.tv_usec = 0;
        setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    return y_mk_long(cfd);  // -1 on error
}

YValue *y_builtin_tcp_read(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_LONG || args[1]->type != Y_LONG)
        return y_mk_str("");
    int fd = (int)args[0]->data.l;
    long max = args[1]->data.l;
    if (max <= 0) max = 65536;
    if (max > 1048576) max = 1048576;
    char *buf = malloc((size_t)max + 1);
    ssize_t n = read(fd, buf, (size_t)max);
    if (n < 0) n = 0;
    buf[n] = '\0';
    YValue *v = y_mk_str_n(buf, (size_t)n);
    free(buf);
    return v;
}

YValue *y_builtin_tcp_write(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc < 2 || args[0]->type != Y_LONG || args[1]->type != Y_STR)
        return y_mk_long(-1);
    int fd = (int)args[0]->data.l;
    const char *data = args[1]->data.s;
    size_t total = strlen(data);
    size_t sent = 0;
    while (sent < total) {
        ssize_t n = write(fd, data + sent, total - sent);
        if (n <= 0) break;
        sent += (size_t)n;
    }
    return y_mk_long((long)sent);
}

YValue *y_builtin_tcp_close(YScope *closure, YValue **args, size_t argc) {
    (void)closure;
    if (argc >= 1 && args[0]->type == Y_LONG) {
        close((int)args[0]->data.l);
    }
    return y_mk_null();
}
