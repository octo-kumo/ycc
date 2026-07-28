#include "runtime.h"
#include <inttypes.h>

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
    arr->count = count;
    /* Copy the pointer array to the heap — the caller's array may be
     * stack-allocated (e.g. from a GCC statement expression). */
    if (count > 0 && elements) {
        arr->elements = malloc(sizeof(YValue *) * count);
        memcpy(arr->elements, elements, sizeof(YValue *) * count);
    } else {
        arr->elements = NULL;
    }
    val->data.arr = arr;
    return val;
}

YValue *y_mk_map(YMapEntry *entries, size_t count) {
    YValue *val = malloc(sizeof(YValue));
    val->type = Y_MAP;
    YMap *map = malloc(sizeof(YMap));
    map->count = count;
    /* Copy entries to the heap — the caller's array may be stack-allocated. */
    if (count > 0 && entries) {
        map->entries = malloc(sizeof(YMapEntry) * count);
        memcpy(map->entries, entries, sizeof(YMapEntry) * count);
    } else {
        map->entries = NULL;
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
    YScopeEntry *e = scope->entries;
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

void y_scope_set(YScope *scope, const char *name, YValue *value) {
    /* Update existing binding in this scope or parent */
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
        YValue **elems = malloc(sizeof(YValue *) * val->data.arr->count);
        for (size_t i = 0; i < val->data.arr->count; i++)
            elems[i] = y_clone(val->data.arr->elements[i]);
        return y_mk_arr(elems, val->data.arr->count);
    }
    case Y_MAP: {
        YMapEntry *entries =
            malloc(sizeof(YMapEntry) * val->data.map->count);
        for (size_t i = 0; i < val->data.map->count; i++) {
            entries[i].key = strdup(val->data.map->entries[i].key);
            entries[i].value = y_clone(val->data.map->entries[i].value);
        }
        return y_mk_map(entries, val->data.map->count);
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
        for (size_t i = 0; i < val->data.arr->count; i++)
            y_free(val->data.arr->elements[i]);
        free(val->data.arr->elements);
        free(val->data.arr);
        break;
    case Y_MAP:
        for (size_t i = 0; i < val->data.map->count; i++) {
            free(val->data.map->entries[i].key);
            y_free(val->data.map->entries[i].value);
        }
        free(val->data.map->entries);
        free(val->data.map);
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
    char *buf = malloc(4096);
    buf[0] = '\0';
    y_to_buf(val, buf, 4096);
    return buf;
}

void y_print(YValue *val) {
    char *s = y_to_str(val);
    printf("[print] %s\n", s);
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
        if (a->type == Y_LONG && b->type == Y_LONG)                           \
            return y_mk_long(a->data.l op b->data.l);                         \
        double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;        \
        double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;        \
        return y_mk_float(av op bv);                                          \
    }

NUMERIC_BINOP(y_sub, -)
NUMERIC_BINOP(y_mul, *)

YValue *y_add(YValue *a, YValue *b) {
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
        YValue *v = malloc(sizeof(YValue));
        v->type = Y_STR;
        v->data.s = result;
        return v;
    }
    if (a->type == Y_LONG && b->type == Y_LONG)
        return y_mk_long(a->data.l + b->data.l);
    double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;
    double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;
    return y_mk_float(av + bv);
}

YValue *y_div(YValue *a, YValue *b) {
    if (a->type == Y_LONG && b->type == Y_LONG) {
        if (b->data.l == 0) {
            fprintf(stderr, "runtime error: division by zero\n");
            exit(1);
        }
        return y_mk_long(a->data.l / b->data.l);
    }
    double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;
    double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;
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
    return y_mk_long(a->data.l % b->data.l);
}

#define CMP_BINOP(name, op)                                                    \
    YValue *name(YValue *a, YValue *b) {                                      \
        if (a->type == Y_LONG && b->type == Y_LONG)                           \
            return y_mk_bool(a->data.l op b->data.l);                         \
        double av = a->type == Y_LONG ? (double)a->data.l : a->data.f;        \
        double bv = b->type == Y_LONG ? (double)b->data.l : b->data.f;        \
        return y_mk_bool(av op bv);                                           \
    }

CMP_BINOP(y_lt, <)
CMP_BINOP(y_gt, >)
CMP_BINOP(y_lte, <=)
CMP_BINOP(y_gte, >=)

YValue *y_eq(YValue *a, YValue *b) { return y_mk_bool(y_equals(a, b)); }
YValue *y_neq(YValue *a, YValue *b) { return y_mk_bool(!y_equals(a, b)); }

YValue *y_and(YValue *a, YValue *b) {
    return y_mk_bool(a->data.b && b->data.b);
}
YValue *y_or(YValue *a, YValue *b) {
    return y_mk_bool(a->data.b || b->data.b);
}

YValue *y_neg(YValue *a) {
    if (a->type == Y_LONG) return y_mk_long(-a->data.l);
    return y_mk_float(-a->data.f);
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
    return y_clone(arr->data.arr->elements[i]);
}

YValue *y_arr_slice(YValue *arr, YValue *start_v, YValue *end_v) {
    if (arr->type != Y_ARR) {
        fprintf(stderr, "runtime error: slicing a non-array\n");
        exit(1);
    }
    long count = (long)arr->data.arr->count;
    long start = start_v->data.l;
    long end = end_v->data.l;

    if (count <= 1 && start >= 1) {
        return y_mk_arr(NULL, 0);
    }

    start = ((start % count) + count) % count;
    end = ((end % count) + count) % count;

    bool reversed = false;
    if (end < start) {
        reversed = true;
        long tmp = start;
        start = end;
        end = tmp;
    }

    size_t n = (size_t)(end - start + 1);
    YValue **elems = malloc(sizeof(YValue *) * n);
    for (size_t i = 0; i < n; i++) {
        long idx = (start + (long)i) % count;
        elems[i] = y_clone(arr->data.arr->elements[idx]);
    }
    if (reversed) {
        for (size_t i = 0; i < n / 2; i++) {
            YValue *tmp = elems[i];
            elems[i] = elems[n - 1 - i];
            elems[n - 1 - i] = tmp;
        }
    }
    return y_mk_arr(elems, n);
}

YValue *y_map_get(YValue *map, const char *key) {
    if (map->type != Y_MAP) return NULL;
    for (size_t i = 0; i < map->data.map->count; i++) {
        if (strcmp(map->data.map->entries[i].key, key) == 0)
            return map->data.map->entries[i].value;
    }
    return NULL;
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
    return y_mk_arr(elems, n);
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
            strncat(buf, "?", sz - strlen(buf) - 1);
            if (i + 1 < val->data.func->arity)
                strncat(buf, ", ", sz - strlen(buf) - 1);
        }
        strncat(buf, ")->?", sz - strlen(buf) - 1);
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

/* ── String escaping ────────────────────────────────────────────────────── */

char *y_escape_c_string(const char *s, size_t len) {
    /* Worst case: every char becomes \xNN (4 chars) */
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
                j += sprintf(out + j, "\\x%02x", c);
            } else {
                out[j++] = (char)c;
            }
        }
    }
    out[j] = '\0';
    return out;
}
