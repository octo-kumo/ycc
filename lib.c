#include "ast.h"
#include "type.h"
#include "typecheck.h"
#include "vm.h"
#include <stdio.h>
#include <sys/wait.h>

#define DEFINE_EXTERNAL_FUNC(name, param_name, param_type_base,                \
                             return_type_base, body_code)                      \
    /* 1. The actual C implementation */                                       \
    VMValue *external_##name(VMVariableScope *scope) {                         \
        VMValue *param_name = vm_scope_get(scope, #param_name);                \
        body_code                                                              \
    }                                                                          \
    /* 2. The Type definition */                                               \
    type_t *name##_type = &(type_t){                                           \
        .base = VAL_FUNC,                                                      \
        .as.func =                                                             \
            {                                                                  \
                .param_count = 1,                                              \
                .param_types =                                                 \
                    (type_t *[]){&(type_t){.base = param_type_base}},          \
                .return_type = &(type_t){.base = return_type_base},            \
            },                                                                 \
    };                                                                         \
    /* 3. The VMValue Function Object (external: closure with NULL scope) */  \
    static Expr __ext_expr_##name = {                                        \
        .kind = EXPR_EFUNC,                                                  \
        .as.efunc =                                                          \
            {                                                                \
                .param_count = 1,                                            \
                .param_names = (char *[]){#param_name},                      \
                .param_types =                                               \
                    (type_t *[]){&(type_t){.base = param_type_base}},        \
                .body = (void *)external_##name,                             \
                .external = true,                                            \
            },                                                               \
    };                                                                       \
    static VMClosure __ext_cl_##name = {                                     \
        .func = &__ext_expr_##name, .scope = NULL};                          \
    VMValue *__external_##name##_func = &(VMValue){                          \
        .type = VAL_FUNC, .data.closure = &__ext_cl_##name};

/* Zero-argument external builtin. */
#define DEFINE_EXTERNAL_FUNC0(name, return_type_base, body_code)             \
    VMValue *external_##name(VMVariableScope *scope) {                       \
        (void)scope;                                                         \
        body_code                                                            \
    }                                                                        \
    type_t *name##_type = &(type_t){                                         \
        .base = VAL_FUNC,                                                    \
        .as.func =                                                           \
            {                                                                \
                .param_count = 0,                                            \
                .param_types = NULL,                                         \
                .return_type = &(type_t){.base = return_type_base},          \
            },                                                               \
    };                                                                       \
    static Expr __ext_expr0_##name = {                                       \
        .kind = EXPR_EFUNC,                                                  \
        .as.efunc =                                                          \
            {                                                                \
                .param_count = 0,                                            \
                .param_names = NULL,                                         \
                .param_types = NULL,                                         \
                .body = (void *)external_##name,                             \
                .external = true,                                            \
            },                                                               \
    };                                                                       \
    static VMClosure __ext_cl0_##name = {                                    \
        .func = &__ext_expr0_##name, .scope = NULL};                         \
    VMValue *__external_##name##_func = &(VMValue){                          \
        .type = VAL_FUNC, .data.closure = &__ext_cl0_##name};

/* Program argv, set by main() before running the VM. */
static int g_vm_argc = 0;
static char **g_vm_argv = NULL;
void vm_set_argv(int argc, char **argv) {
    g_vm_argc = argc;
    g_vm_argv = argv;
}

DEFINE_EXTERNAL_FUNC(print, x, _VAL_INFERRED, VAL_NULL, {
    if (x) {
        printf("[print] ");
        val_print(x);
        printf("\n");
    } else {
        printf("print: missing argument 'x'\n");
    }
    return nval(VAL_NULL);
});
DEFINE_EXTERNAL_FUNC(tostring, x, _VAL_INFERRED, VAL_STR, {
    if (x) {
        VMValue *result = nval(VAL_STR);
        result->data.s = val_to_str(x);
        return result;
    } else {
        printf("tostring: missing argument 'x'\n");
        return nval(VAL_NULL);
    }
});
DEFINE_EXTERNAL_FUNC(typeof, x, _VAL_INFERRED, VAL_TYPE, {
    if (x) {
        VMValue *result = nval(VAL_TYPE);
        result->data.type = val_type(x);
        return result;
    } else {
        printf("typeof: missing argument 'x'\n");
        return nval(VAL_NULL);
    }
});
DEFINE_EXTERNAL_FUNC(range, x, VAL_LONG, VAL_ARR, {
    if (x) {
        if (x->type != VAL_LONG) {
            printf("range: argument must be a long\n");
            return nval(VAL_NULL);
        }
        long n = x->data.l;
        if (n < 0) {
            printf("range: argument must be non-negative\n");
            return nval(VAL_NULL);
        }
        VMValue *result = nval(VAL_ARR);
        VMArray *arr = malloc(sizeof(VMArray));
        result->data.arr = arr;
        result->data.arr->count = n;
        result->data.arr->elements = malloc(sizeof(VMValue *) * n);
        for (long i = 0; i < n; i++) {
            result->data.arr->elements[i] = nval(VAL_LONG);
            result->data.arr->elements[i]->data.l = i;
        }
        return result;
    } else {
        printf("range: missing argument 'x'\n");
        return nval(VAL_NULL);
    }
});

/* ── Multi-param builtins (manual, macro only supports 1 param) ─────────── */

#define DEFINE_EXTERNAL_FUNC2(name, p1, p2, body_code)                         \
    VMValue *external_##name(VMVariableScope *scope) {                         \
        VMValue *p1 = vm_scope_get(scope, #p1);                               \
        VMValue *p2 = vm_scope_get(scope, #p2);                               \
        body_code                                                              \
    }                                                                          \
    type_t *name##_type = &(type_t){                                           \
        .base = VAL_FUNC,                                                      \
        .as.func =                                                             \
            {                                                                  \
                .param_count = 2,                                              \
                .param_types =                                                 \
                    (type_t *[]){&(type_t){.base = _VAL_INFERRED},             \
                                 &(type_t){.base = _VAL_INFERRED}},            \
                .return_type = &(type_t){.base = _VAL_INFERRED},               \
            },                                                                 \
    };                                                                         \
    static Expr __ext_expr_##name = {                                        \
        .kind = EXPR_EFUNC,                                                  \
        .as.efunc =                                                          \
            {                                                                \
                .param_count = 2,                                            \
                .param_names = (char *[]){#p1, #p2},                         \
                .param_types =                                               \
                    (type_t *[]){&(type_t){.base = _VAL_INFERRED},           \
                                 &(type_t){.base = _VAL_INFERRED}},          \
                .body = (void *)external_##name,                             \
                .external = true,                                            \
            },                                                               \
    };                                                                       \
    static VMClosure __ext_cl_##name = {                                     \
        .func = &__ext_expr_##name, .scope = NULL};                          \
    VMValue *__external_##name##_func = &(VMValue){                          \
        .type = VAL_FUNC, .data.closure = &__ext_cl_##name};

#define DEFINE_EXTERNAL_FUNC3(name, p1, p2, p3, body_code)                     \
    VMValue *external_##name(VMVariableScope *scope) {                         \
        VMValue *p1 = vm_scope_get(scope, #p1);                               \
        VMValue *p2 = vm_scope_get(scope, #p2);                               \
        VMValue *p3 = vm_scope_get(scope, #p3);                               \
        body_code                                                              \
    }                                                                          \
    type_t *name##_type = &(type_t){                                           \
        .base = VAL_FUNC,                                                      \
        .as.func =                                                             \
            {                                                                  \
                .param_count = 3,                                              \
                .param_types =                                                 \
                    (type_t *[]){&(type_t){.base = _VAL_INFERRED},             \
                                 &(type_t){.base = _VAL_INFERRED},             \
                                 &(type_t){.base = _VAL_INFERRED}},            \
                .return_type = &(type_t){.base = _VAL_INFERRED},               \
            },                                                                 \
    };                                                                         \
    static Expr __ext_expr_##name = {                                        \
        .kind = EXPR_EFUNC,                                                  \
        .as.efunc =                                                          \
            {                                                                \
                .param_count = 3,                                            \
                .param_names = (char *[]){#p1, #p2, #p3},                    \
                .param_types =                                               \
                    (type_t *[]){&(type_t){.base = _VAL_INFERRED},           \
                                 &(type_t){.base = _VAL_INFERRED},           \
                                 &(type_t){.base = _VAL_INFERRED}},          \
                .body = (void *)external_##name,                             \
                .external = true,                                            \
            },                                                               \
    };                                                                       \
    static VMClosure __ext_cl_##name = {                                     \
        .func = &__ext_expr_##name, .scope = NULL};                          \
    VMValue *__external_##name##_func = &(VMValue){                          \
        .type = VAL_FUNC, .data.closure = &__ext_cl_##name};

/* readline() -> str | null */
DEFINE_EXTERNAL_FUNC(readline, x, _VAL_INFERRED, VAL_STR, {
    (void)x;
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) { free(line); return nval(VAL_NULL); }
    if (n > 0 && line[n - 1] == '\n') line[--n] = '\0';
    VMValue *result = nval(VAL_STR);
    result->data.s = line;
    return result;
});

/* puts(s) — raw output, no prefix, no newline */
DEFINE_EXTERNAL_FUNC(puts, x, _VAL_INFERRED, VAL_NULL, {
    if (x) {
        char *s = val_to_str(x);
        fputs(s, stdout);
        fflush(stdout);
        free(s);
    }
    return nval(VAL_NULL);
});

/* len(x) -> long */
DEFINE_EXTERNAL_FUNC(len, x, _VAL_INFERRED, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    if (!x) { result->data.l = 0; return result; }
    switch (x->type) {
    case VAL_STR: result->data.l = (long)strlen(x->data.s); break;
    case VAL_ARR: result->data.l = (long)x->data.arr->count; break;
    default: result->data.l = 0;
    }
    return result;
});

/* trim(s) -> str */
DEFINE_EXTERNAL_FUNC(trim, x, _VAL_INFERRED, VAL_STR, {
    if (!x || x->type != VAL_STR) {
        VMValue *r = nval(VAL_STR); r->data.s = strdup(""); return r;
    }
    const char *s = x->data.s;
    while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
    size_t slen = strlen(s);
    while (slen > 0 && (s[slen-1]==' '||s[slen-1]=='\t'||s[slen-1]=='\n'||s[slen-1]=='\r'))
        slen--;
    VMValue *result = nval(VAL_STR);
    result->data.s = strndup(s, slen);
    return result;
});

/* exec(cmd) -> long — SECURITY: passes cmd to /bin/sh -c via system().
 * Shell metacharacters are interpreted. Intentional escape hatch; do not
 * feed it untrusted input unsanitized. See runtime.c for full note. */
DEFINE_EXTERNAL_FUNC(exec, x, _VAL_INFERRED, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    if (!x || x->type != VAL_STR) { result->data.l = -1; return result; }
    int ret = system(x->data.s);
    result->data.l = WIFEXITED(ret) ? WEXITSTATUS(ret) : -1;
    return result;
});

/* argv() -> [str]  (command-line arguments) */
DEFINE_EXTERNAL_FUNC0(argv, VAL_ARR, {
    VMValue *result = nval(VAL_ARR);
    VMArray *arr = malloc(sizeof(VMArray));
    arr->count = g_vm_argc > 0 ? (size_t)g_vm_argc : 0;
    arr->elements = malloc(sizeof(VMValue *) * (arr->count > 0 ? arr->count : 1));
    for (int i = 0; i < g_vm_argc; i++) {
        arr->elements[i] = nval(VAL_STR);
        arr->elements[i]->data.s = strdup(g_vm_argv[i]);
    }
    result->data.arr = arr;
    return result;
});

/* tonum(s) -> long */
DEFINE_EXTERNAL_FUNC(tonum, x, _VAL_INFERRED, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    if (!x) { result->data.l = 0; return result; }
    if (x->type == VAL_LONG) { result->data.l = x->data.l; return result; }
    if (x->type == VAL_FLOAT) { result->data.l = (long)x->data.f; return result; }
    if (x->type != VAL_STR) { result->data.l = 0; return result; }
    char *end;
    result->data.l = strtol(x->data.s, &end, 10);
    if (end == x->data.s) result->data.l = 0;
    return result;
});

/* split(s, delim) -> [str] */
DEFINE_EXTERNAL_FUNC2(split, s, delim, {
    if (!s || s->type != VAL_STR || !delim || delim->type != VAL_STR) {
        VMValue *r = nval(VAL_ARR);
        VMArray *a = malloc(sizeof(VMArray)); a->count = 0; a->elements = NULL;
        r->data.arr = a; return r;
    }
    const char *str = s->data.s;
    const char *d = delim->data.s;
    size_t dlen = strlen(d);
    if (dlen == 0) {
        VMValue *r = nval(VAL_ARR);
        VMArray *a = malloc(sizeof(VMArray)); a->count = 0; a->elements = NULL;
        r->data.arr = a; return r;
    }
    size_t count = 0;
    const char *p = str;
    while (*p) { count++; const char *nx = strstr(p, d); p = nx ? nx + dlen : p + strlen(p); }
    VMValue **elems = malloc(sizeof(VMValue *) * (count > 0 ? count : 1));
    size_t i = 0; p = str;
    while (*p) {
        const char *nx = strstr(p, d);
        size_t len = nx ? (size_t)(nx - p) : strlen(p);
        elems[i] = nval(VAL_STR); elems[i]->data.s = strndup(p, len); i++;
        p = nx ? nx + dlen : p + strlen(p);
    }
    VMValue *result = nval(VAL_ARR);
    VMArray *arr = malloc(sizeof(VMArray));
    arr->count = count; arr->elements = elems;
    result->data.arr = arr;
    return result;
});

/* join(arr, delim) -> str */
DEFINE_EXTERNAL_FUNC2(join, arr, delim, {
    VMValue *result = nval(VAL_STR);
    if (!arr || arr->type != VAL_ARR || !delim || delim->type != VAL_STR) {
        result->data.s = strdup(""); return result;
    }
    size_t total = 1;
    for (size_t i = 0; i < arr->data.arr->count; i++) {
        char *s = val_to_str(arr->data.arr->elements[i]);
        total += strlen(s) + strlen(delim->data.s);
        free(s);
    }
    char *buf = malloc(total);
    buf[0] = '\0';
    for (size_t i = 0; i < arr->data.arr->count; i++) {
        if (i > 0) strcat(buf, delim->data.s);
        char *s = val_to_str(arr->data.arr->elements[i]);
        strcat(buf, s);
        free(s);
    }
    result->data.s = buf;
    return result;
});

/* push(arr, val) -> arr */
DEFINE_EXTERNAL_FUNC2(push, arr, val, {
    if (!arr || arr->type != VAL_ARR) {
        VMValue *r = nval(VAL_ARR);
        VMArray *a = malloc(sizeof(VMArray)); a->count = 0; a->elements = NULL;
        r->data.arr = a; return r;
    }
    size_t n = arr->data.arr->count + 1;
    VMValue **elems = malloc(sizeof(VMValue *) * n);
    for (size_t i = 0; i < arr->data.arr->count; i++)
        elems[i] = val_clone(arr->data.arr->elements[i]);
    elems[arr->data.arr->count] = val_clone(val);
    VMValue *result = nval(VAL_ARR);
    VMArray *a = malloc(sizeof(VMArray));
    a->count = n; a->elements = elems;
    result->data.arr = a;
    return result;
});

/* substr(s, start, len) -> str */
DEFINE_EXTERNAL_FUNC3(substr, s, start, count, {
    VMValue *result = nval(VAL_STR);
    if (!s || s->type != VAL_STR) { result->data.s = strdup(""); return result; }
    long slen = (long)strlen(s->data.s);
    long st = start ? start->data.l : 0;
    long cnt = count ? count->data.l : slen;
    if (st < 0) st = 0;
    if (st >= slen) { result->data.s = strdup(""); return result; }
    if (cnt < 0 || st + cnt > slen) cnt = slen - st;
    result->data.s = strndup(s->data.s + st, (size_t)cnt);
    return result;
});

/* read_file(path) -> str | null */
DEFINE_EXTERNAL_FUNC(read_file, x, _VAL_INFERRED, VAL_STR, {
    if (!x || x->type != VAL_STR) return nval(VAL_NULL);
    FILE *f = fopen(x->data.s, "rb");
    if (!f) return nval(VAL_NULL);
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return nval(VAL_NULL); }
    char *buf = malloc((size_t)sz + 1);
    size_t rd = fread(buf, 1, (size_t)sz, f);
    buf[rd] = '\0';
    fclose(f);
    VMValue *result = nval(VAL_STR);
    result->data.s = buf;
    return result;
});

/* write_file(path, content) -> bool */
DEFINE_EXTERNAL_FUNC2(write_file, path, content, {
    VMValue *result = nval(VAL_BOOL);
    if (!path || path->type != VAL_STR || !content || content->type != VAL_STR) {
        result->data.b = false; return result;
    }
    FILE *f = fopen(path->data.s, "wb");
    if (!f) { result->data.b = false; return result; }
    size_t n = strlen(content->data.s);
    size_t wr = fwrite(content->data.s, 1, n, f);
    fclose(f);
    result->data.b = (wr == n);
    return result;
});

/* ord(s) -> long (code point of first char, -1 if empty) */
DEFINE_EXTERNAL_FUNC(ord, x, _VAL_INFERRED, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    if (!x || x->type != VAL_STR || x->data.s[0] == '\0') {
        result->data.l = -1; return result;
    }
    result->data.l = (long)(unsigned char)x->data.s[0];
    return result;
});

/* chr(n) -> str (single-byte string from code point) */
DEFINE_EXTERNAL_FUNC(chr, x, _VAL_INFERRED, VAL_STR, {
    VMValue *result = nval(VAL_STR);
    if (!x) { result->data.s = strdup(""); return result; }
    char buf[2];
    buf[0] = (char)(x->data.l & 0xFF);
    buf[1] = '\0';
    result->data.s = strndup(buf, 1);
    return result;
});

/* index_of(s, sub) -> long (first index of sub in s, -1 if not found) */
DEFINE_EXTERNAL_FUNC2(index_of, s, sub, {
    VMValue *result = nval(VAL_LONG);
    if (!s || s->type != VAL_STR || !sub || sub->type != VAL_STR) {
        result->data.l = -1; return result;
    }
    const char *hit = strstr(s->data.s, sub->data.s);
    result->data.l = hit ? (long)(hit - s->data.s) : -1;
    return result;
});

void populate_types(TCVarTypeScope *scope) {
    map_set(&scope->variables, "print", print_type);
    map_set(&scope->variables, "tostring", tostring_type);
    map_set(&scope->variables, "typeof", typeof_type);
    map_set(&scope->variables, "range", range_type);
    map_set(&scope->variables, "readline", readline_type);
    map_set(&scope->variables, "puts", puts_type);
    map_set(&scope->variables, "split", split_type);
    map_set(&scope->variables, "len", len_type);
    map_set(&scope->variables, "trim", trim_type);
    map_set(&scope->variables, "exec", exec_type);
    map_set(&scope->variables, "argv", argv_type);
    map_set(&scope->variables, "tonum", tonum_type);
    map_set(&scope->variables, "join", join_type);
    map_set(&scope->variables, "push", push_type);
    map_set(&scope->variables, "substr", substr_type);
    map_set(&scope->variables, "read_file", read_file_type);
    map_set(&scope->variables, "write_file", write_file_type);
    map_set(&scope->variables, "ord", ord_type);
    map_set(&scope->variables, "chr", chr_type);
    map_set(&scope->variables, "index_of", index_of_type);
}
void populate_scope(VMVariableScope *scope) {
    map_set(&scope->variables, "print", __external_print_func);
    map_set(&scope->variables, "tostring", __external_tostring_func);
    map_set(&scope->variables, "typeof", __external_typeof_func);
    map_set(&scope->variables, "range", __external_range_func);
    map_set(&scope->variables, "readline", __external_readline_func);
    map_set(&scope->variables, "puts", __external_puts_func);
    map_set(&scope->variables, "split", __external_split_func);
    map_set(&scope->variables, "len", __external_len_func);
    map_set(&scope->variables, "trim", __external_trim_func);
    map_set(&scope->variables, "exec", __external_exec_func);
    map_set(&scope->variables, "argv", __external_argv_func);
    map_set(&scope->variables, "tonum", __external_tonum_func);
    map_set(&scope->variables, "join", __external_join_func);
    map_set(&scope->variables, "push", __external_push_func);
    map_set(&scope->variables, "substr", __external_substr_func);
    map_set(&scope->variables, "read_file", __external_read_file_func);
    map_set(&scope->variables, "write_file", __external_write_file_func);
    map_set(&scope->variables, "ord", __external_ord_func);
    map_set(&scope->variables, "chr", __external_chr_func);
    map_set(&scope->variables, "index_of", __external_index_of_func);
}