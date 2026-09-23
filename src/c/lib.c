#include "ast.h"
#include "type.h"
#include "typecheck.h"
#include "vm.h"
#include <malloc.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>

/* Security switch: disables the `exec` builtin (see lib.h). */
int g_exec_disabled = 0;
void set_exec_disabled(int disabled) { g_exec_disabled = disabled; }

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
        VMArray *arr = vm_arr_alloc();
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

/* readline() -> str | null
 * EOF is NOT latched: clearerr() puts the stream back in a readable state so
 * a later readline() sees new input (Ctrl-D in a REPL, a reopened FIFO).
 * That matches the native backend, which reads fd 0 directly and has no
 * sticky EOF flag to begin with. */
DEFINE_EXTERNAL_FUNC0(readline, VAL_STR, {
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        clearerr(stdin);
        return nval(VAL_NULL);
    }
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

/* exit(code) -> ! (process exit; an FFI necessity, not library bloat) */
DEFINE_EXTERNAL_FUNC(exit, code, VAL_LONG, VAL_NULL, {
    int c = 0;
    if (code && code->type == VAL_LONG) c = (int)(code->data.l & 0xff);
    exit(c);
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
    VMArray *arr = vm_arr_alloc();
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
        VMArray *a = vm_arr_alloc(); a->count = 0; a->elements = NULL;
        r->data.arr = a; return r;
    }
    const char *str = s->data.s;
    const char *d = delim->data.s;
    size_t dlen = strlen(d);
    if (dlen == 0) {
        VMValue *r = nval(VAL_ARR);
        VMArray *a = vm_arr_alloc(); a->count = 0; a->elements = NULL;
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
    VMArray *arr = vm_arr_alloc();
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

/* push(arr, val) -> arr — grows the array IN PLACE (reference semantics,
 * matching the compiled runtime and the native backend) and returns it.
 * Callers rebind (`a = push(a, v)`); aliases observe the new element. */
DEFINE_EXTERNAL_FUNC2(push, arr, val, {
    if (!arr || arr->type != VAL_ARR) {
        VMValue *r = nval(VAL_ARR);
        r->data.arr = vm_arr_alloc();
        return r;
    }
    VMArray *a = arr->data.arr;
    if (a->count + 1 > a->capacity) {
        size_t newcap = a->capacity < 8 ? 8 : a->capacity * 2;
        if (newcap < a->count + 1) newcap = a->count + 1;
        a->elements = realloc(a->elements, sizeof(VMValue *) * newcap);
        a->capacity = newcap;
    }
    a->elements[a->count] = val_clone(val);
    a->count++;
    return val_clone(arr);
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

/* some(v) -> v — options are value-or-null on this toolchain (no wrapper):
 * some is the identity (cloned for ownership safety). */
DEFINE_EXTERNAL_FUNC(some, x, _VAL_INFERRED, _VAL_INFERRED, {
    if (!x) return nval(VAL_NULL);
    return val_clone(x);
});

/* is_some(v) -> bool — true unless v is null. */
DEFINE_EXTERNAL_FUNC(is_some, x, _VAL_INFERRED, VAL_BOOL, {
    VMValue *result = nval(VAL_BOOL);
    result->data.b = (x && x->type != VAL_NULL);
    return result;
});

/* unwrap(v) -> v — identity (cloned); LOUD failure on null (programmer
 * error: forgot the `== null` check). Matches native gen_unwrap (trap). */
DEFINE_EXTERNAL_FUNC(unwrap, x, _VAL_INFERRED, _VAL_INFERRED, {
    if (!x || x->type == VAL_NULL) {
        fprintf(stderr, "runtime error: unwrap of null\n");
        exit(1);
    }
    return val_clone(x);
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

/* write_bytes(path, bytes, mode) -> bool: binary-safe file write + chmod.
 * Like tinycc's tcc_write_elf_file output step (open/write/chmod): bytes
 * arrive as [long] (0-255, NULs included — Y strings cannot carry NUL);
 * mode is applied via chmod(2), -1 skips. The ycc driver uses this to emit
 * executables (elf.y byte arrays) with no shell/exec. */
DEFINE_EXTERNAL_FUNC3(write_bytes, path, bytes, mode, {
    VMValue *result = nval(VAL_BOOL);
    result->data.b = false;
    if (!path || path->type != VAL_STR || !bytes || bytes->type != VAL_ARR) {
        return result;
    }
    long m = (mode && mode->type == VAL_LONG) ? mode->data.l : -1;
    size_t n = bytes->data.arr->count;
    char *buf = malloc(n ? n : 1);
    if (!buf) return result;
    for (size_t i = 0; i < n; i++) {
        VMValue *e = bytes->data.arr->elements[i];
        buf[i] = (char)(e && e->type == VAL_LONG ? (e->data.l & 0xFF) : 0);
    }
    FILE *f = fopen(path->data.s, "wb");
    if (!f) { free(buf); return result; }
    size_t wr = fwrite(buf, 1, n, f);
    fclose(f);
    free(buf);
    if (wr != n) return result;
    if (m >= 0) {
        if (chmod(path->data.s, (mode_t)m) != 0) return result;
    }
    result->data.b = true;
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

/* clear_eof() -> null
 * Clear the end-of-input condition so a later readline() reads again.
 * examples/ysh.y drains stdin to EOF to collect a multi-line body, then
 * calls this to keep the REPL alive. Harmless when stdin is not at EOF. */
DEFINE_EXTERNAL_FUNC0(clear_eof, VAL_NULL, {
    clearerr(stdin);
    return nval(VAL_NULL);
});

/* bytes(s) -> [byte]  (raw bytes of a string; a plain long array here —
 * only the native backend packs them one byte per element) */
DEFINE_EXTERNAL_FUNC(bytes, x, _VAL_INFERRED, VAL_ARR, {
    VMValue *result = nval(VAL_ARR);
    VMArray *arr = vm_arr_alloc();
    size_t n = (x && x->type == VAL_STR) ? strlen(x->data.s) : 0;
    arr->count = n;
    arr->elements = malloc(sizeof(VMValue *) * (n > 0 ? n : 1));
    for (size_t i = 0; i < n; i++) {
        arr->elements[i] = nval(VAL_LONG);
        arr->elements[i]->data.l = (unsigned char)x->data.s[i];
    }
    result->data.arr = arr;
    return result;
});

/* from_bytes(b) -> str  (inverse of bytes()) */
DEFINE_EXTERNAL_FUNC(from_bytes, x, _VAL_INFERRED, VAL_STR, {
    VMValue *result = nval(VAL_STR);
    if (!x || x->type != VAL_ARR) { result->data.s = strdup(""); return result; }
    size_t n = x->data.arr->count;
    char *buf = malloc(n + 1);
    for (size_t i = 0; i < n; i++) {
        VMValue *e = x->data.arr->elements[i];
        buf[i] = (char)((e && e->type == VAL_LONG) ? (e->data.l & 0xFF) : 0);
    }
    buf[n] = '\0';
    result->data.s = buf;
    return result;
});

/* getenv(name) -> str|null (read an environment variable) */
DEFINE_EXTERNAL_FUNC(getenv, x, _VAL_INFERRED, _VAL_INFERRED, {
    if (!x || x->type != VAL_STR) { return nval(VAL_NULL); }
    const char *val = getenv(x->data.s);
    if (!val) { return nval(VAL_NULL); }
    VMValue *result = nval(VAL_STR);
    result->data.s = strdup(val);
    return result;
});

/* ── TCP networking builtins ─────────────────────────────────────────────
 * Real socket implementations live in runtime.c (used by the compiled
 * native path). These VM-side stubs exist so the typechecker recognizes the
 * names and so VM-mode programs get a clean "unsupported" error rather than
 * "undefined variable". The challenge server uses the compiled path. */
DEFINE_EXTERNAL_FUNC(tcp_listen, port, _VAL_INFERRED, VAL_LONG, {
    (void)port; VMValue *r = nval(VAL_LONG); r->data.l = -1; return r;
});
DEFINE_EXTERNAL_FUNC(tcp_accept, fd, _VAL_INFERRED, VAL_LONG, {
    (void)fd; VMValue *r = nval(VAL_LONG); r->data.l = -1; return r;
});
DEFINE_EXTERNAL_FUNC2(tcp_read, fd, max, {
    (void)fd; (void)max; VMValue *r = nval(VAL_STR); r->data.s = strdup(""); return r;
});
DEFINE_EXTERNAL_FUNC2(tcp_write, fd, data, {
    (void)fd; (void)data; VMValue *r = nval(VAL_LONG); r->data.l = -1; return r;
});
DEFINE_EXTERNAL_FUNC(tcp_close, fd, _VAL_INFERRED, VAL_NULL, {
    (void)fd; return nval(VAL_NULL);
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

/* last_index_of(s, sub) -> long (last index of sub in s, -1 if not found) */
DEFINE_EXTERNAL_FUNC2(last_index_of, s, sub, {
    VMValue *result = nval(VAL_LONG);
    if (!s || s->type != VAL_STR || !sub || sub->type != VAL_STR) {
        result->data.l = -1; return result;
    }
    const char *last = NULL;
    const char *p = s->data.s;
    while ((p = strstr(p, sub->data.s)) != NULL) {
        last = p;
        p++;
    }
    result->data.l = last ? (long)(last - s->data.s) : -1;
    return result;
});

/* arr_index_of(arr, val) -> long (first index where arr[i] == val, -1 if not found) */
DEFINE_EXTERNAL_FUNC2(arr_index_of, arr, val, {
    VMValue *result = nval(VAL_LONG);
    if (!arr || arr->type != VAL_ARR) {
        result->data.l = -1; return result;
    }
    long idx = -1;
    for (size_t i = 0; i < arr->data.arr->count; i++) {
        VMValue *elem = arr->data.arr->elements[i];
        bool eq = false;
        if (elem->type == VAL_LONG && val->type == VAL_LONG) eq = (elem->data.l == val->data.l);
        else if (elem->type == VAL_STR && val->type == VAL_STR) eq = (strcmp(elem->data.s, val->data.s) == 0);
        else if (elem->type == VAL_BOOL && val->type == VAL_BOOL) eq = (elem->data.b == val->data.b);
        if (eq) { idx = (long)i; break; }
    }
    result->data.l = idx;
    return result;
});

/* map_get(map, key) -> value (null if not found) */
DEFINE_EXTERNAL_FUNC2(map_get, m, key, {
    if (!m || m->type != VAL_MAP || !key || key->type != VAL_STR) {
        return nval(VAL_NULL);
    }
    VMMap *vm = m->data.map;
    for (size_t i = 0; i < vm->count; i++) {
        if (strcmp(vm->entries[i].key, key->data.s) == 0) {
            return val_clone(vm->entries[i].value);
        }
    }
    return nval(VAL_NULL);
});

/* map_set(map, key, val) -> null (mutates map in place) */
DEFINE_EXTERNAL_FUNC3(map_set, m, key, val, {
    if (m && m->type == VAL_MAP && key && key->type == VAL_STR) {
        VMMap *vm = m->data.map;
        for (size_t i = 0; i < vm->count; i++) {
            if (strcmp(vm->entries[i].key, key->data.s) == 0) {
                val_free(vm->entries[i].value);
                vm->entries[i].value = val_clone(val);
                return nval(VAL_NULL);
            }
        }
        vm->entries = realloc(vm->entries, sizeof(VMMapEntry) * (vm->count + 1));
        vm->entries[vm->count].key = strdup(key->data.s);
        vm->entries[vm->count].value = val_clone(val);
        vm->count++;
    }
    return nval(VAL_NULL);
});

/* eputs(s) — raw output to stderr, no prefix, no newline. Diagnostics go
 * here so they never mix into a program's stdout (or into `-S` output). */
DEFINE_EXTERNAL_FUNC(eputs, x, _VAL_INFERRED, VAL_NULL, {
    if (x) {
        char *s = val_to_str(x);
        fputs(s, stderr);
        fflush(stderr);
        free(s);
    }
    return nval(VAL_NULL);
});

/* sleep(ms) -> null: suspend the calling program for ms milliseconds.
 * Backed by nanosleep(2); a signal interruption sleeps out the remainder. */
DEFINE_EXTERNAL_FUNC(sleep, ms, VAL_LONG, VAL_NULL, {
    struct timespec req;
    if (ms && ms->type == VAL_LONG && ms->data.l > 0) {
        req.tv_sec = (time_t)(ms->data.l / 1000);
        req.tv_nsec = (long)(ms->data.l % 1000) * 1000000L;
    } else {
        req.tv_sec = 0;
        req.tv_nsec = 0;
    }
    while (nanosleep(&req, &req) != 0 && errno == EINTR) {
    }
    return nval(VAL_NULL);
});

/* clock_us() -> long: monotonic microseconds. Only differences are
 * meaningful (the origin is arbitrary). */
DEFINE_EXTERNAL_FUNC0(clock_us, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        result->data.l = 0;
        return result;
    }
    result->data.l = (long)ts.tv_sec * 1000000L + (long)ts.tv_nsec / 1000L;
    return result;
});

/* heap_used() -> long: bytes of heap currently handed out. The native
 * backend reports its arena break, so across engines only deltas between
 * two samples are comparable. */
DEFINE_EXTERNAL_FUNC0(heap_used, VAL_LONG, {
    VMValue *result = nval(VAL_LONG);
    struct mallinfo2 mi = mallinfo2();
    result->data.l = (long)mi.uordblks;
    return result;
});

void populate_types(TCVarTypeScope *scope) {
    map_set(&scope->variables, "print", print_type);
    map_set(&scope->variables, "tostring", tostring_type);
    map_set(&scope->variables, "typeof", typeof_type);
    map_set(&scope->variables, "range", range_type);
    map_set(&scope->variables, "readline", readline_type);
    map_set(&scope->variables, "puts", puts_type);
    map_set(&scope->variables, "exit", exit_type);
    map_set(&scope->variables, "split", split_type);
    map_set(&scope->variables, "len", len_type);
    map_set(&scope->variables, "trim", trim_type);
    if (!g_exec_disabled) map_set(&scope->variables, "exec", exec_type);
    map_set(&scope->variables, "argv", argv_type);
    map_set(&scope->variables, "tonum", tonum_type);
    map_set(&scope->variables, "join", join_type);
    map_set(&scope->variables, "push", push_type);
    map_set(&scope->variables, "substr", substr_type);
    map_set(&scope->variables, "read_file", read_file_type);
    map_set(&scope->variables, "write_file", write_file_type);
    map_set(&scope->variables, "write_bytes", write_bytes_type);
    map_set(&scope->variables, "ord", ord_type);
    map_set(&scope->variables, "chr", chr_type);
    map_set(&scope->variables, "clear_eof", clear_eof_type);
    map_set(&scope->variables, "bytes", bytes_type);
    map_set(&scope->variables, "from_bytes", from_bytes_type);
    map_set(&scope->variables, "index_of", index_of_type);
    map_set(&scope->variables, "last_index_of", last_index_of_type);
    map_set(&scope->variables, "arr_index_of", arr_index_of_type);
    map_set(&scope->variables, "map_get", map_get_type);
    map_set(&scope->variables, "map_set", map_set_type);
    map_set(&scope->variables, "getenv", getenv_type);
    map_set(&scope->variables, "tcp_listen", tcp_listen_type);
    map_set(&scope->variables, "tcp_accept", tcp_accept_type);
    map_set(&scope->variables, "tcp_read", tcp_read_type);
    map_set(&scope->variables, "tcp_write", tcp_write_type);
    map_set(&scope->variables, "tcp_close", tcp_close_type);
    map_set(&scope->variables, "eputs", eputs_type);
    map_set(&scope->variables, "sleep", sleep_type);
    map_set(&scope->variables, "clock_us", clock_us_type);
    map_set(&scope->variables, "heap_used", heap_used_type);
}
void populate_scope(VMVariableScope *scope) {
    map_set(&scope->variables, "print", __external_print_func);
    map_set(&scope->variables, "tostring", __external_tostring_func);
    map_set(&scope->variables, "typeof", __external_typeof_func);
    map_set(&scope->variables, "range", __external_range_func);
    map_set(&scope->variables, "readline", __external_readline_func);
    map_set(&scope->variables, "puts", __external_puts_func);
    map_set(&scope->variables, "exit", __external_exit_func);
    map_set(&scope->variables, "split", __external_split_func);
    map_set(&scope->variables, "len", __external_len_func);
    map_set(&scope->variables, "trim", __external_trim_func);
    if (!g_exec_disabled) map_set(&scope->variables, "exec", __external_exec_func);
    map_set(&scope->variables, "argv", __external_argv_func);
    map_set(&scope->variables, "tonum", __external_tonum_func);
    map_set(&scope->variables, "join", __external_join_func);
    map_set(&scope->variables, "push", __external_push_func);
    map_set(&scope->variables, "substr", __external_substr_func);
    map_set(&scope->variables, "read_file", __external_read_file_func);
    map_set(&scope->variables, "some", __external_some_func);
    map_set(&scope->variables, "is_some", __external_is_some_func);
    map_set(&scope->variables, "unwrap", __external_unwrap_func);
    map_set(&scope->variables, "write_file", __external_write_file_func);
    map_set(&scope->variables, "write_bytes", __external_write_bytes_func);
    map_set(&scope->variables, "ord", __external_ord_func);
    map_set(&scope->variables, "chr", __external_chr_func);
    map_set(&scope->variables, "clear_eof", __external_clear_eof_func);
    map_set(&scope->variables, "bytes", __external_bytes_func);
    map_set(&scope->variables, "from_bytes", __external_from_bytes_func);
    map_set(&scope->variables, "index_of", __external_index_of_func);
    map_set(&scope->variables, "last_index_of", __external_last_index_of_func);
    map_set(&scope->variables, "arr_index_of", __external_arr_index_of_func);
    map_set(&scope->variables, "map_get", __external_map_get_func);
    map_set(&scope->variables, "map_set", __external_map_set_func);
    map_set(&scope->variables, "getenv", __external_getenv_func);
    map_set(&scope->variables, "tcp_listen", __external_tcp_listen_func);
    map_set(&scope->variables, "tcp_accept", __external_tcp_accept_func);
    map_set(&scope->variables, "tcp_read", __external_tcp_read_func);
    map_set(&scope->variables, "tcp_write", __external_tcp_write_func);
    map_set(&scope->variables, "tcp_close", __external_tcp_close_func);
    map_set(&scope->variables, "eputs", __external_eputs_func);
    map_set(&scope->variables, "sleep", __external_sleep_func);
    map_set(&scope->variables, "clock_us", __external_clock_us_func);
    map_set(&scope->variables, "heap_used", __external_heap_used_func);
}