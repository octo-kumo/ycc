#ifndef YRUNTIME_H
#define YRUNTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Value types ─────────────────────────────────────────────────────────── */

typedef enum {
    Y_LONG,
    Y_FLOAT,
    Y_BOOL,
    Y_STR,
    Y_NULL,
    Y_ARR,
    Y_MAP,
    Y_FUNC,
} YType;

typedef struct YValue YValue;

typedef struct {
    int refcount;
    size_t count;
    size_t capacity;   /* allocated slots (>= count); enables O(1) amortized push */
    YValue **elements;
} YArray;

typedef struct {
    char *key;
    YValue *value;
} YMapEntry;

typedef struct {
    int refcount;
    size_t count;
    YMapEntry *entries;
} YMap;

/* Compiled function signature: takes closure scope + args array */
struct YScope;
typedef YValue *(*YFuncPtr)(struct YScope *closure, YValue **args,
                            size_t argc);

typedef struct {
    YFuncPtr fn;
    size_t arity;
    struct YScope *closure; /* captured scope, ref-counted */
} YFunc;

struct YValue {
    YType type;
    union {
        long l;
        double f;
        bool b;
        char *s;
        YArray *arr;
        YMap *map;
        YFunc *func;
    } data;
};

/* ── Scope (linked list, ref-counted for closures) ──────────────────────── */

typedef struct YScopeEntry {
    char *name;
    YValue *value;
    struct YScopeEntry *next;
} YScopeEntry;

typedef struct YScope {
    YScopeEntry *entries;
    struct YScope *parent;
    int refcount;
} YScope;

/* ── Constructors ───────────────────────────────────────────────────────── */

YValue *y_mk_long(long v);
YValue *y_mk_float(double v);
YValue *y_mk_bool(bool v);
YValue *y_mk_str(const char *s);
YValue *y_mk_str_n(const char *s, size_t len);
YValue *y_mk_null(void);
YValue *y_mk_arr(YValue **elements, size_t count);
YValue *y_mk_map(YMapEntry *entries, size_t count);
YValue *y_mk_func(YFuncPtr fn, size_t arity, YScope *closure);

/* ── Scope operations ───────────────────────────────────────────────────── */

void y_scope_init(YScope *scope, YScope *parent);
YScope *y_scope_retain(YScope *scope);
void y_scope_release(YScope *scope);
YValue *y_scope_get(YScope *scope, const char *name);
YValue *y_scope_take(YScope *scope, const char *name);
void y_scope_set(YScope *scope, const char *name, YValue *value);
void y_scope_set_local(YScope *scope, const char *name, YValue *value);

/* ── Value operations ───────────────────────────────────────────────────── */

YValue *y_clone(YValue *val);
void y_free(YValue *val);
char *y_to_str(YValue *val); /* caller must free */
void y_print(YValue *val);
bool y_equals(YValue *a, YValue *b);

/* ── Arithmetic / logic ─────────────────────────────────────────────────── */

YValue *y_add(YValue *a, YValue *b);
YValue *y_sub(YValue *a, YValue *b);
YValue *y_mul(YValue *a, YValue *b);
YValue *y_div(YValue *a, YValue *b);
YValue *y_mod(YValue *a, YValue *b);
YValue *y_lt(YValue *a, YValue *b);
YValue *y_gt(YValue *a, YValue *b);
YValue *y_lte(YValue *a, YValue *b);
YValue *y_gte(YValue *a, YValue *b);
YValue *y_eq(YValue *a, YValue *b);
YValue *y_neq(YValue *a, YValue *b);
YValue *y_and(YValue *a, YValue *b);
YValue *y_or(YValue *a, YValue *b);
YValue *y_neg(YValue *a);

/* ── Array / map operations ─────────────────────────────────────────────── */

YValue *y_arr_index(YValue *arr, YValue *idx);
YValue *y_arr_index_borrow(YValue *arr, YValue *idx);
YValue *y_arr_slice(YValue *arr, YValue *start, YValue *end);
YValue *y_map_get(YValue *map, const char *key);
YValue *y_cons(YValue *head, YValue *tail);

/* ── Function calls ─────────────────────────────────────────────────────── */

YValue *y_call(YValue *callee, YValue **args, size_t argc);

/* ── Built-in functions ─────────────────────────────────────────────────── */

YValue *y_builtin_print(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tostring(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_range(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_typeof(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_readline(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_puts(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_exit(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_split(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_len(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_trim(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_exec(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_argv(YScope *closure, YValue **args, size_t argc);
void y_set_argv(int argc, char **argv);
YValue *y_builtin_tonum(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_join(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_push(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_substr(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_read_file(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_some(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_is_some(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_unwrap(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_write_file(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_write_bytes(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_ord(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_chr(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_clear_eof(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_bytes(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_from_bytes(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_ord_at(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_eputs(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_sleep(YScope *closure, YValue **args, size_t argc);
/* Map construction helpers (used by spread: `{a: 1, ...b}`). */
void y_map_put(YValue *map, const char *key, YValue *val);
void y_map_merge(YValue *dst, YValue *src);
YValue *y_builtin_clock_us(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_heap_used(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_bytes_to_str(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_ensure_runtime(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_gen_embedded_runtime(YScope *closure, YValue **args, size_t argc);

/* Self-contained runtime embedding (C layer). */
const char *y_ensure_runtime(void);
int y_gen_embedded_runtime(const char *src_dir, const char *out_dir);
YValue *y_builtin_index_of(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_arr_index_of(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_last_index_of(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_getenv(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tcp_listen(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tcp_accept(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tcp_read(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tcp_write(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tcp_close(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_map_set(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_map_get(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_global_get(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_scope_new(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_scope_def(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_scope_find(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_scope_get(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_scope_set(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tok_type(YScope *closure, YValue **args, size_t argc);
YValue *y_builtin_tok_value(YScope *closure, YValue **args, size_t argc);

/* arr_set(arr, idx, val) — mutate array element in place */
void y_arr_set(YValue *arr, YValue *idx, YValue *val);

/* ── String escaping (for codegen string literals) ──────────────────────── */

char *y_escape_c_string(const char *s, size_t len);

#endif /* YRUNTIME_H */
