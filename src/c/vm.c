#include "vm.h"
#include "ast.h"
#include "ast_debug.h"
#include "lib.h"
#include "map.h"
#include "type.h"
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>

/* The tree-walking VM recurses on the C stack (several frames per Y call),
 * so runaway recursion must be caught before the guard page is. Frame sizes
 * vary too much for a fixed call count to be safe, so the guard measures
 * actual stack use against the process limit. */
static char *g_vm_stack_base = NULL;
static char *g_vm_stack_floor = NULL;

/* Set by `return`, cleared by the call that catches it. While set, blocks
 * and loops stop iterating so the value unwinds to the function boundary. */
static int g_vm_returning = 0;

/* ASan must not instrument these two: with its fake stack the `probe`
 * locals move off the real stack, and the guard then compares unrelated
 * addresses (it either never fires or fires immediately). */
#if defined(__GNUC__)
#define VM_STACK_PROBE __attribute__((no_sanitize_address, noinline))
#else
#define VM_STACK_PROBE
#endif

static VM_STACK_PROBE void vm_stack_guard_init(void) {
    char *here = (char *)__builtin_frame_address(0);
    size_t lim = 8u * 1024 * 1024; /* default if RLIMIT_STACK is unavailable */
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY &&
        rl.rlim_cur > 0)
        lim = (size_t)rl.rlim_cur;
    /* Leave headroom: the error path itself needs stack, and libc/ASan
     * frames are bigger than ours. The floor is an ADDRESS, so the check is
     * a pointer comparison — subtracting from a base captured in a deeper
     * frame than the one being checked would wrap around instead. */
    g_vm_stack_base = here;
    g_vm_stack_floor = here - (lim - lim / 4);
}

static VM_STACK_PROBE void vm_stack_check(void) {
    if (!g_vm_stack_floor) return;
    char *here = (char *)__builtin_frame_address(0);
    if (here < g_vm_stack_floor) {
        ptrdiff_t used = g_vm_stack_base - here;
        if (used < 0) used = 0;
        fprintf(stderr, "Maximum recursion depth exceeded (call stack "
                        "exhausted after %zu KB)\n",
                (size_t)used / 1024);
        exit(1);
    }
}

VMValue *nval(ValueType type) {
    VMValue *val = malloc(sizeof(VMValue));
    val->type = type;
    return val;
}

bool val_equals(VMValue *left, VMValue *right) {
    if (!left || !right)
        return left == right; // if either is NULL, only equal if both are NULL
    if (left == right) {
        return true;
    } // same pointer means equal (also handles NULL)
    if (left->type != right->type) { return false; }
    // if (memcmp(left, right, sizeof(VMValue)) == 0) {
    //     // if the raw bytes are the same, we consider them equal
    //     return true;
    // }
    switch (left->type) {
    case VAL_LONG: return left->data.l == right->data.l;
    case VAL_FLOAT: return left->data.f == right->data.f;
    case VAL_BOOL: return left->data.b == right->data.b;
    case VAL_STR: return strcmp(left->data.s, right->data.s) == 0;
    case VAL_NULL: return true;
    case VAL_TYPE:
        return left->data.type ==
               right->data.type; // TODO: two different type_t might be equal
                                 // too, handle in future
    case VAL_FUNC: return left->data.closure == right->data.closure;
    case VAL_ARR: {
        if (left->data.arr->count != right->data.arr->count) { return false; }
        for (size_t i = 0; i < left->data.arr->count; i++) {
            if (!val_equals(left->data.arr->elements[i],
                            right->data.arr->elements[i])) {
                return false;
            }
        }
        return true;
    }
    case VAL_MAP: {
        if (left->data.map->count != right->data.map->count) { return false; }
        for (size_t i = 0; i < left->data.map->count; i++) {
            char *key = left->data.map->entries[i].key;
            VMValue *left_val = left->data.map->entries[i].value;
            VMValue *right_val = NULL;
            for (size_t j = 0; j < right->data.map->count; j++) {
                if (strcmp(key, right->data.map->entries[j].key) == 0) {
                    right_val = right->data.map->entries[j].value;
                    break;
                }
            }
            if (!right_val || !val_equals(left_val, right_val)) {
                return false;
            }
        }
        return true;
    }
    case _VAL_INFERRED:
        return false; // Placeholder - implement inferred equality
    }
    return false;
}
void val_print(const VMValue *val) { char *s = val_to_str(val); printf("%s", s); free(s); }
void val_to_buf(const VMValue *val, char *buf, size_t buf_size) {
    if (buf_size <= 1) return; // Safety check

    switch (val->type) {
    case VAL_LONG: snprintf(buf, buf_size, "%ld", val->data.l); break;
    case VAL_FLOAT: snprintf(buf, buf_size, "%f", val->data.f); break;
    case VAL_BOOL:
        snprintf(buf, buf_size, "%s", val->data.b ? "true" : "false");
        break;
    case VAL_STR: snprintf(buf, buf_size, "%s", val->data.s); break;
    case VAL_TYPE:
        snprintf(buf, buf_size, "%s", type_t_to_str(val->data.type));
        break;
    case VAL_FUNC: {
        char param_types_str[256] = "";
        for (size_t i = 0; i < val->data.closure->func->as.efunc.param_count; i++) {
            char type_str[64];
            type_t_to_buf(val->data.closure->func->as.efunc.param_types[i], type_str,
                          sizeof(type_str));
            strncat(param_types_str, type_str,
                    sizeof(param_types_str) - strlen(param_types_str) - 1);
            if (i < val->data.closure->func->as.efunc.param_count - 1) {
                strncat(param_types_str, ", ",
                        sizeof(param_types_str) - strlen(param_types_str) - 1);
            }
        }
        char return_type_str[64] = "";
        type_t_to_buf(val->data.closure->func->as.efunc.return_type, return_type_str,
                      sizeof(return_type_str));
        snprintf(buf, buf_size, "<function (%s)->(%s)>", param_types_str,
                 return_type_str);
        break;
    }
    case VAL_NULL: snprintf(buf, buf_size, "null"); break;
    case VAL_ARR: {
        snprintf(buf, buf_size, "[");
        for (size_t i = 0; i < val->data.arr->count; i++) {
            size_t current_len = strlen(buf);
            // Recurse directly into the remaining space of the buffer
            val_to_buf(val->data.arr->elements[i], buf + current_len,
                       buf_size - current_len);

            if (i < val->data.arr->count - 1) {
                strncat(buf, ", ", buf_size - strlen(buf) - 1);
            }
        }
        strncat(buf, "]", buf_size - strlen(buf) - 1);
        break;
    }
    case VAL_MAP: {
        snprintf(buf, buf_size, "{");
        for (size_t i = 0; i < val->data.map->count; i++) {
            char *escaped_key = escape_str(val->data.map->entries[i].key);
            strncat(buf, escaped_key, buf_size - strlen(buf) - 1);
            free(escaped_key);

            strncat(buf, ": ", buf_size - strlen(buf) - 1);

            size_t current_len = strlen(buf);
            val_to_buf(val->data.map->entries[i].value, buf + current_len,
                       buf_size - current_len);

            if (i < val->data.map->count - 1) {
                strncat(buf, ", ", buf_size - strlen(buf) - 1);
            }
        }
        strncat(buf, "}", buf_size - strlen(buf) - 1);
        break;
    }
    case _VAL_INFERRED: snprintf(buf, buf_size, "<inferred>"); break;
    }
}
char *val_to_str(const VMValue *val) {
    char *buf = malloc(4096);
    buf[0] = '\0';
    val_to_buf(val, buf, 4096);
    return buf;
}
type_t *val_type(const VMValue *val) {
    switch (val->type) {
    case VAL_LONG: return TYPE_LONG;
    case VAL_FLOAT: return TYPE_FLOAT;
    case VAL_BOOL: return TYPE_BOOL;
    case VAL_STR: return TYPE_STR;
    case VAL_FUNC: {
        type_t *func_type = tc_make_t(VAL_FUNC);
        func_type->as.func.param_count = val->data.closure->func->as.efunc.param_count;
        func_type->as.func.param_types = val->data.closure->func->as.efunc.param_types;
        func_type->as.func.return_type = val->data.closure->func->as.efunc.return_type;
        return func_type;
    }
    case VAL_TYPE: {
        type_t *type_type = tc_make_t(VAL_TYPE);
        type_type->as.type = val->data.type;
        return type_type;
    }
    case VAL_NULL: return TYPE_NULL;
    case VAL_ARR: {
        type_t *arr_type = tc_make_t(VAL_ARR);
        arr_type->as.array.element_type =
            val->data.arr->count > 0
                ? val_type(val->data.arr->elements[0])
                : _TYPE_INFERRED;
        return arr_type;
    }
    case VAL_MAP: {
        type_t *map_type = tc_make_t(VAL_MAP);
        map_type->as.map.count = val->data.map->count;
        map_type->as.map.entries =
            malloc(sizeof(type_map_entry_t) * map_type->as.map.count);
        for (size_t i = 0; i < map_type->as.map.count; i++) {
            strncpy(map_type->as.map.entries[i].key,
                    val->data.map->entries[i].key, 32);
            map_type->as.map.entries[i].value =
                val_type(val->data.map->entries[i].value);
        }
        return map_type;
    }
    case _VAL_INFERRED:
        return _TYPE_INFERRED; // Placeholder - implement inferred types
                               // properly
    }
    return NULL; // should never reach here
}
VMArray *vm_arr_alloc(void) {
    VMArray *a = malloc(sizeof(VMArray));
    a->refcount = 1;
    a->count = 0;
    a->capacity = 0;
    a->elements = NULL;
    return a;
}

VMMap *vm_map_alloc(void) {
    VMMap *m = malloc(sizeof(VMMap));
    m->refcount = 1;
    m->count = 0;
    m->entries = NULL;
    return m;
}

/* Arrays and maps are REFERENCE values: cloning shares the body and bumps
 * the refcount, and the mutating builtins (push, map_set) mutate in place.
 * The compiled C runtime and the native backend behave the same way, so all
 * three engines agree. Deep-copying here instead made every `push` on a
 * record field O(n) and whole compiles O(n^2). */
VMValue *val_clone(const VMValue *src) {
    if (src->type == VAL_FUNC && src->data.closure->scope == NULL) {
        // external functions are singletons, so we just return the same pointer
        return (VMValue *)src;
    }
    VMValue *dst = nval(src->type);
    switch (src->type) {
    case VAL_LONG: dst->data.l = src->data.l; break;
    case VAL_BOOL: dst->data.b = src->data.b; break;
    case VAL_STR: dst->data.s = strdup(src->data.s); break;
    case VAL_FUNC: {
        VMClosure *c = malloc(sizeof(VMClosure));
        c->func = src->data.closure->func;
        c->scope = vm_scope_retain(src->data.closure->scope);
        dst->data.closure = c;
        break;
    }
    case VAL_NULL: break;
    case VAL_TYPE:
        dst->data.type = src->data.type;
        break; // types are immutable, so we can just copy the pointer
    case _VAL_INFERRED: break;
    case VAL_FLOAT: dst->data.f = src->data.f; break;
    case VAL_ARR: {
        dst->data.arr = src->data.arr;
        dst->data.arr->refcount++;
        break;
    }
    case VAL_MAP: {
        dst->data.map = src->data.map;
        dst->data.map->refcount++;
        break;
    }
    }
    return dst;
}
void val_free(VMValue *val) {
    if (!val) return;
    switch (val->type) {
    case VAL_STR: free(val->data.s); break;

    case _VAL_INFERRED: break;
    case VAL_FUNC: {
        if (val->data.closure->scope == NULL) {
            // external functions are static singletons; never free them
            return;
        }
        vm_scope_release(val->data.closure->scope);
        free(val->data.closure);
        break;
    }
    case VAL_LONG:
    case VAL_BOOL:
    case VAL_NULL:
    case VAL_FLOAT: break;
    case VAL_ARR: {
        if (--val->data.arr->refcount > 0) break;
        for (size_t i = 0; i < val->data.arr->count; i++) {
            val_free(val->data.arr->elements[i]);
        }
        free(val->data.arr->elements);
        free(val->data.arr);
        break;
    }
    case VAL_MAP: {
        if (--val->data.map->refcount > 0) break;
        for (size_t i = 0; i < val->data.map->count; i++) {
            free(val->data.map->entries[i].key);
            val_free(val->data.map->entries[i].value);
        }
        free(val->data.map->entries);
        free(val->data.map);
        break;
    }
    case VAL_TYPE: {
        // all types are centrally managed, so we don't free them here
        break;
    }
    }
    free(val);
}

VMValue *vm_scope_get(VMVariableScope *scope, const char *name) {
    /* Iterative: the scope chain is as deep as the call stack, so recursing
     * here could exhaust the stack between two vm_stack_check() probes. */
    for (VMVariableScope *s = scope; s; s = s->parent) {
        VMValue *val = map_get(&s->variables, name);
        if (val) return val;
    }
    return NULL;
}
void vm_scope_set(VMVariableScope *scope, const char *name, VMValue *value) {
    /* Walk up the scope chain to find an existing binding to update */
    for (VMVariableScope *s = scope; s; s = s->parent) {
        VMValue *existing = map_get(&s->variables, name);
        if (existing) {
            val_free(existing);
            map_set(&s->variables, name, val_clone(value));
            return;
        }
    }
    /* No existing binding — create in current scope */
    map_set(&scope->variables, name, val_clone(value));
}

/* Bind in the CURRENT scope only (never walks up). Used for `let`/`const`/
 * `def` declarations so a local never clobbers an outer binding with the
 * same name (true shadowing; reads and `=` still walk up). */
void vm_scope_set_local(VMVariableScope *scope, const char *name,
                        VMValue *value) {
    VMValue *existing = map_get(&scope->variables, name);
    if (existing) val_free(existing);
    map_set(&scope->variables, name, val_clone(value));
}

VMVariableScope *vm_scope_new(VMVariableScope *parent) {
    VMVariableScope *s = malloc(sizeof(VMVariableScope));
    s->parent = parent;
    s->refcount = 1;
    map_init(&s->variables);
    return s;
}

VMVariableScope *vm_scope_retain(VMVariableScope *scope) {
    if (scope) scope->refcount++;
    return scope;
}

void vm_scope_release(VMVariableScope *scope) {
    if (!scope) return;
    if (--scope->refcount > 0) return;
    for (size_t i = 0; i < scope->variables.len; i++) {
        val_free(scope->variables.items[i].value);
    }
    map_free(&scope->variables);
    free(scope);
}

void vm_init(VM *vm) {
    vm_stack_guard_init();
    vm->globals = vm_scope_new(NULL);
    populate_scope(vm->globals);
}

/* Compatibility wrapper: release a heap scope (drops one reference). */
void vm_scope_free(VMVariableScope *scope) { vm_scope_release(scope); }

size_t byte_len(const char *s) { return strlen(s); }

static VMValue *vm_execute_inner(VMVariableScope *scope, Expr *expr);

VMValue *vm_execute(VMVariableScope *scope, Expr *expr) {
    return vm_execute_inner(scope, expr);
}

static VMValue *vm_execute_inner(VMVariableScope *scope, Expr *expr) {
    switch (expr->kind) {
    case EXPR_ELONG: {
        VMValue *val = nval(VAL_LONG);
        val->data.l = expr->as.elong;
        return val;
    }
    case EXPR_EFLOAT: {
        VMValue *val = nval(VAL_FLOAT);
        val->data.f = expr->as.efloat;
        return val;
    }
    case EXPR_EBOOL: {
        VMValue *val = nval(VAL_BOOL);
        val->data.b = expr->as.ebool;
        return val;
    }
    case EXPR_ENULL: {
        return nval(VAL_NULL);
    }
    case EXPR_EVAR: {
        VMValue *val = vm_scope_get(scope, expr->as.evar);
        if (!val) {
            fprintf(stderr, "Undefined variable: %s\n", expr->as.evar);
            exit(1);
        }
        return val_clone(val);
    }
    case EXPR_EIF: {
        VMValue *cond = vm_execute(scope, expr->as.if_node.cond);
        if (cond->type != VAL_BOOL) {
            fprintf(stderr, "Condition must be a boolean\n");
            exit(1);
        }
        bool condition = cond->data.b;
        val_free(cond);
        if (condition) {
            return vm_execute(scope, expr->as.if_node.then_branch);
        } else if (expr->as.if_node.else_branch) {
            return vm_execute(scope, expr->as.if_node.else_branch);
        } else {
            VMValue *val = nval(VAL_NULL);
            return val;
        }
    }
    case EXPR_EUNARY: {
        VMValue *operand = vm_execute(scope, expr->as.unary_node.operand);
        if (expr->as.unary_node.op == O_NOT) {
            if (operand->type != VAL_BOOL) {
                fprintf(stderr, "Operand of '!' must be boolean\n");
                exit(1);
            }
            VMValue *val = nval(VAL_BOOL);
            val->data.b = !operand->data.b;
            val_free(operand);
            return val;
        } else if (expr->as.unary_node.op == O_NEG) {
            if (operand->type == VAL_LONG) {
                VMValue *val = nval(VAL_LONG);
                /* Negate through unsigned: -LONG_MIN is signed-overflow UB,
                 * and wrapping back to LONG_MIN is the documented result. */
                val->data.l = (long)(0UL - (unsigned long)operand->data.l);
                val_free(operand);
                return val;
            } else if (operand->type == VAL_FLOAT) {
                VMValue *val = nval(VAL_FLOAT);
                val->data.f = -operand->data.f;
                val_free(operand);
                return val;
            } else {
                fprintf(stderr, "Operand of unary '-' must be numeric\n");
                exit(1);
            }
        } else {
            fprintf(stderr, "Unknown unary operator\n");
            exit(1);
        }
    }
    case EXPR_EOP: {
        /* Short-circuit: `&&` and `||` must not evaluate the right operand
         * when the left already decides the result. Guards like
         * `if (i < len(a) && a[i] == x)` depend on it; evaluating both
         * sides eagerly is why src/y/*.y is full of nested ifs. */
        if (expr->as.op_node.op == O_AND || expr->as.op_node.op == O_OR) {
            VMValue *lhs = vm_execute(scope, expr->as.op_node.left);
            if (lhs->type != VAL_BOOL) {
                fprintf(stderr, "Operands must be booleans\n");
                exit(1);
            }
            bool lb = lhs->data.b;
            val_free(lhs);
            bool decided = expr->as.op_node.op == O_AND ? !lb : lb;
            VMValue *res = nval(VAL_BOOL);
            if (decided) {
                res->data.b = lb;
                return res;
            }
            VMValue *rhs = vm_execute(scope, expr->as.op_node.right);
            if (rhs->type != VAL_BOOL) {
                fprintf(stderr, "Operands must be booleans\n");
                exit(1);
            }
            res->data.b = rhs->data.b;
            val_free(rhs);
            return res;
        }
        VMValue *left = vm_execute(scope, expr->as.op_node.left);
        VMValue *right = expr->as.op_node.op == O_DOT
                             ? NULL
                             : vm_execute(scope, expr->as.op_node.right);

#define __REQUIRES_NUMERIC()                                                   \
    if ((left->type != VAL_LONG && left->type != VAL_FLOAT) ||                 \
        (right->type != VAL_LONG && right->type != VAL_FLOAT)) {               \
        fprintf(stderr, "Operands must be numbers\n");                         \
        exit(1);                                                               \
    }
#define __REQUIRES_BOOL()                                                      \
    if (left->type != VAL_BOOL || right->type != VAL_BOOL) {                   \
        fprintf(stderr, "Operands must be booleans\n");                        \
        exit(1);                                                               \
    }
#define __ISCOMPARISON(op)                                                     \
    if (left->type == VAL_STR && right->type == VAL_STR) {                     \
        /* Lexicographic, byte by byte — the ordering `str` needs for         \
         * sorting. strcmp's sign is all that is portable, so compare it. */   \
        val->data.b = strcmp(left->data.s, right->data.s) op 0;                \
    } else {                                                                   \
        __REQUIRES_NUMERIC();                                                  \
        if (left->type == VAL_LONG && right->type == VAL_LONG) {               \
            val->data.b = left->data.l op right->data.l;                       \
        } else {                                                               \
            double left_val =                                                  \
                left->type == VAL_LONG ? left->data.l : left->data.f;          \
            double right_val =                                                 \
                right->type == VAL_LONG ? right->data.l : right->data.f;       \
            val->data.b = left_val op right_val;                               \
        }                                                                      \
    }                                                                          \
    val->type = VAL_BOOL;
#define __ISCALCULATION(op)                                                    \
    __REQUIRES_NUMERIC();                                                      \
    if (left->type == VAL_LONG && right->type == VAL_LONG) {                   \
        /* Wrap through unsigned: signed overflow is UB, and two's            \
         * complement wrapping is the behaviour the compiled backend and      \
         * the native backend already have (audit t37_long_overflow). */      \
        val->data.l = (long)((unsigned long)left->data.l op(unsigned long)     \
                                 right->data.l);                              \
        val->type = VAL_LONG;                                                  \
    } else {                                                                   \
        double left_val =                                                      \
            left->type == VAL_LONG ? left->data.l : left->data.f;              \
        double right_val =                                                     \
            right->type == VAL_LONG ? right->data.l : right->data.f;           \
        val->data.f = left_val op right_val;                                   \
        val->type = VAL_FLOAT;                                                 \
    }

        VMValue *val = nval(VAL_LONG);
        switch (expr->as.op_node.op) {
        case O_GTE: {
            __ISCOMPARISON(>=);
            break;
        }
        case O_LTE: {
            __ISCOMPARISON(<=);
            break;
        }
        case O_AND: {
            __REQUIRES_BOOL();
            val->data.b = left->data.b && right->data.b;
            val->type = VAL_BOOL;
            break;
        }
        case O_OR: {
            __REQUIRES_BOOL();
            val->data.b = left->data.b || right->data.b;
            val->type = VAL_BOOL;
            break;
        }
        case O_EQ: {
            val->data.b = val_equals(left, right);
            val->type = VAL_BOOL;
            break;
        }
        case O_NEQ: {
            val->data.b = !val_equals(left, right);
            val->type = VAL_BOOL;
            break;
        }
        case O_ADD: {
            // special case, if any one side is string, this is string
            // concat operator
            // Arrays win over strings: `arr + arr` concatenates, `arr + x`
            // appends and `x + arr` prepends, always producing a NEW array
            // (the operands are untouched -- that is what makes `+` the
            // explicit-copy counterpart of the in-place `push`).
            if (left->type == VAL_ARR || right->type == VAL_ARR) {
                size_t ln = left->type == VAL_ARR ? left->data.arr->count : 1;
                size_t rn = right->type == VAL_ARR ? right->data.arr->count : 1;
                VMArray *out = vm_arr_alloc();
                out->count = ln + rn;
                out->capacity = out->count;
                out->elements = malloc(sizeof(VMValue *) * (out->count ? out->count : 1));
                size_t k = 0;
                if (left->type == VAL_ARR)
                    for (size_t i = 0; i < ln; i++)
                        out->elements[k++] = val_clone(left->data.arr->elements[i]);
                else
                    out->elements[k++] = val_clone(left);
                if (right->type == VAL_ARR)
                    for (size_t i = 0; i < rn; i++)
                        out->elements[k++] = val_clone(right->data.arr->elements[i]);
                else
                    out->elements[k++] = val_clone(right);
                val->type = VAL_ARR;
                val->data.arr = out;
                break;
            }
            if (left->type == VAL_STR || right->type == VAL_STR) {
                char *left_str;
                if (left->type == VAL_STR) { left_str = strdup(left->data.s); }
                else { left_str = val_to_str(left); }
                char *right_str;
                if (right->type == VAL_STR) { right_str = strdup(right->data.s); }
                else { right_str = val_to_str(right); }
                size_t concat_len = strlen(left_str) + strlen(right_str) + 1;
                char *concat_str = malloc(concat_len);
                strcpy(concat_str, left_str);
                strncat(concat_str, right_str,
                        concat_len - strlen(concat_str) - 1);
                val->type = VAL_STR;
                val->data.s = concat_str;
                free(left_str);
                free(right_str);
                break;
            }
            __ISCALCULATION(+);
            break;
        }
        case O_SUB: {
            __ISCALCULATION(-);
            break;
        }
        case O_MUL: {
            __ISCALCULATION(*);
            break;
        }
        case O_MOD: {
            if (left->type != VAL_LONG || right->type != VAL_LONG) {
                fprintf(stderr,
                        "Operands of modulus operator must be integers\n");
                exit(1);
            }
            if (right->data.l == 0) {
                fprintf(stderr, "Division by zero in modulus operator\n");
                exit(1);
            }
            /* LONG_MIN % -1 is UB in C and traps on x86 (#DE) even though
             * the answer is 0; special-case it rather than divide. */
            val->data.l = (left->data.l == LONG_MIN && right->data.l == -1)
                              ? 0
                              : left->data.l % right->data.l;
            val->type = VAL_LONG;
            break;
        }
        case O_DIV: {
            if (left->type == VAL_LONG && right->type == VAL_LONG &&
                right->data.l == 0) {
                fprintf(stderr, "Division by zero\n");
                exit(1);
            }
            /* NOT __ISCALCULATION: that wraps operands through unsigned to
             * dodge signed-overflow UB, which is right for + - * but turns
             * division into UNSIGNED division (7 / -2 gave 0, -7 / 2 gave
             * 9223372036854775804). Only LONG_MIN / -1 actually overflows,
             * and both backends wrap it to LONG_MIN. */
            __REQUIRES_NUMERIC();
            if (left->type == VAL_LONG && right->type == VAL_LONG) {
                val->data.l = (left->data.l == LONG_MIN && right->data.l == -1)
                                  ? LONG_MIN
                                  : left->data.l / right->data.l;
                val->type = VAL_LONG;
            } else {
                double lv =
                    left->type == VAL_LONG ? (double)left->data.l : left->data.f;
                double rv = right->type == VAL_LONG ? (double)right->data.l
                                                    : right->data.f;
                val->data.f = lv / rv;
                val->type = VAL_FLOAT;
            }
            break;
        }
        case O_ASSIGN: {
            fprintf(stderr, "Unexpected assignment operator in expression\n");
            exit(1);
        }
        case O_LT: {
            __ISCOMPARISON(<);
            break;
        }
        case O_GT: {
            __ISCOMPARISON(>);
            break;
        }
        case O_CONS: {
            if (right->type != VAL_ARR) {
                fprintf(stderr, "Right operand of :: must be an array\n");
                exit(1);
            }
            VMArray *new_arr = vm_arr_alloc();
            new_arr->count = right->data.arr->count + 1;
            new_arr->elements = malloc(sizeof(VMValue *) * new_arr->count);
            new_arr->elements[0] = val_clone(left);
            for (size_t i = 0; i < right->data.arr->count; i++) {
                new_arr->elements[i + 1] =
                    val_clone(right->data.arr->elements[i]);
            }
            val->type = VAL_ARR;
            val->data.arr = new_arr;
            break;
        }
        case O_DOT: {
            if (left->type == VAL_MAP &&
                expr->as.op_node.right->kind == EXPR_EVAR) {
                // map access with dot notation, e.g. mymap.key
                char *key = expr->as.op_node.right->as.evar;
                VMValue *value = NULL;
                for (size_t i = 0; i < left->data.map->count; i++) {
                    if (strcmp(left->data.map->entries[i].key, key) == 0) {
                        value = left->data.map->entries[i].value;
                        break;
                    }
                }
                if (!value) {
                    fprintf(stderr, "Key '%s' not found in map\n", key);
                    exit(1);
                }
                val = val_clone(value);
            } else {
                fprintf(stderr, "Dot operator is only supported for map access "
                                "with string keys\n");
                exit(1);
            }
        }
        }
        val_free(left);
        val_free(right);
        return val;
    }
    case EXPR_EDECLARATION: {
        VMValue *val = vm_execute(scope, expr->as.declaration_node.value);
        vm_scope_set_local(scope, expr->as.declaration_node.name, val);
        return val;
    }
    case EXPR_EASSIGNMENT: {
        VMValue *val = vm_execute(scope, expr->as.assignment_node.value);
        vm_scope_set(scope, expr->as.assignment_node.var_name, val);
        return val;
    }
    case EXPR_EBLOCK: {
        VMVariableScope *nested_scope = vm_scope_new(scope);
        VMValue *last = nval(VAL_NULL);
        for (size_t i = 0; i < expr->as.block_node.count; i++) {
            val_free(last);
            last = vm_execute(nested_scope, expr->as.block_node.exprs[i]);
            /* `return` unwinds: stop running statements and hand the value
             * up. The enclosing call clears the flag. */
            if (g_vm_returning) break;
        }
        vm_scope_release(nested_scope);
        return last;
    }
    case EXPR_ERETURN: {
        VMValue *val = expr->as.return_value
                           ? vm_execute(scope, expr->as.return_value)
                           : nval(VAL_NULL);
        g_vm_returning = 1;
        return val;
    }
    case EXPR_ECALL: {
        VMValue *callee_val = vm_execute(scope, expr->as.call_node.callee);
        if (callee_val->type == VAL_MAP &&
            expr->as.call_node.callee->kind == EXPR_EOP &&
            expr->as.call_node.callee->as.op_node.op == O_DOT) {
            /* Method-style call m.f(args): f must be a function stored in
             * map m under key f. (Dot chains on call results misparse in
             * user code, but the module system generates m.f(...) calls
             * for every imported function — this is the core dispatch.) */
            Expr *dot = expr->as.call_node.callee;
            char *key = dot->as.op_node.right->kind == EXPR_EVAR
                            ? dot->as.op_node.right->as.evar
                            : NULL;
            VMValue *func_val = NULL;
            if (key) {
                for (size_t i = 0; i < callee_val->data.map->count; i++) {
                    if (strcmp(callee_val->data.map->entries[i].key, key) ==
                        0) {
                        func_val = callee_val->data.map->entries[i].value;
                        break;
                    }
                }
            }
            if (!func_val || func_val->type != VAL_FUNC) {
                fprintf(stderr, "Attempting to call a non-function value\n");
                exit(1);
            }
            val_free(callee_val);
            callee_val = val_clone(func_val);
        }
        if (callee_val->type != VAL_FUNC) {
            fprintf(stderr, "Attempting to call a non-function value\n");
            exit(1);
        }
        VMClosure *cl = callee_val->data.closure;
        Expr *func = cl->func;
        if (func->kind != EXPR_EFUNC) {
            fprintf(stderr, "Attempting to call a non-function value\n");
            exit(1);
        }
        if (func->as.efunc.param_count != expr->as.call_node.arg_count) {
            fprintf(stderr, "Argument count mismatch in function call\n");
            exit(1);
        }
        /* Lexical scoping: the call scope's parent is the closure's captured
         * defining scope (or the caller scope for external builtins, which
         * have no captured scope). */
        VMVariableScope *func_scope =
            vm_scope_new(cl->scope ? cl->scope : scope);
        for (size_t i = 0; i < func->as.efunc.param_count; i++) {
            VMValue *arg_val = vm_execute(scope, expr->as.call_node.args[i]);
            map_set(&func_scope->variables, func->as.efunc.param_names[i],
                    arg_val);
        }
        /* `self` is the recursion handle, but a parameter (or local) of
         * that name is the programmer's, so only bind it when it is free.
         * Otherwise a param named `self` was silently replaced by the
         * function value. */
        int self_is_param = 0;
        for (size_t i = 0; i < func->as.efunc.param_count; i++)
            if (strcmp(func->as.efunc.param_names[i], "self") == 0)
                self_is_param = 1;
        if (!self_is_param)
            map_set(&func_scope->variables, "self", val_clone(callee_val));
        /* Recursion guard: the VM recurses on the C stack, so unbounded Y
         * recursion used to SIGSEGV (audit t10_deep_recursion). Report it
         * as a normal error instead of dying on a guard page. */
        vm_stack_check();
        VMValue *result = func->as.efunc.external
                              ? ((VMValue * (*)(VMVariableScope *))
                                     func->as.efunc.body)(func_scope)
                              : vm_execute(func_scope, func->as.efunc.body);
        /* The function boundary catches `return`: the unwind stops here. */
        g_vm_returning = 0;
        vm_scope_release(func_scope);
        val_free(callee_val);
        return result;
    }
    case EXPR_EFUNC: {
        VMValue *val = nval(VAL_FUNC);
        VMClosure *cl = malloc(sizeof(VMClosure));
        cl->func = expr;
        cl->scope = vm_scope_retain(scope); /* capture lexical environment */
        val->data.closure = cl;
        return val;
    }
    case EXPR_ESTR: {
        VMValue *val = nval(VAL_STR);
        val->data.s = strdup(expr->as.estr.data);
        return val;
    }
    case EXPR_EARRAY: {
        VMArray *arr = vm_arr_alloc();
        arr->count = expr->as.array_node.count;
        arr->elements = malloc(sizeof(VMValue *) * arr->count);
        for (size_t i = 0; i < arr->count; i++) {
            arr->elements[i] =
                vm_execute(scope, expr->as.array_node.elements[i]);
        }
        VMValue *val = nval(VAL_ARR);
        val->data.arr = arr;
        return val;
    }
    case EXPR_EMAP: {
        VMMap *map = vm_map_alloc();
        size_t cap = expr->as.map_node.count;
        map->entries = malloc(sizeof(VMMapEntry) * (cap ? cap : 1));
        size_t n = 0;
        /* Insert (or overwrite) one key; duplicates keep position, last
         * value wins -- the rule spread relies on. */
#define VM_MAP_PUT(k, v)                                                       \
    do {                                                                       \
        size_t existing = n;                                                   \
        for (size_t j = 0; j < n; j++)                                         \
            if (strcmp(map->entries[j].key, (k)) == 0) {                       \
                existing = j;                                                  \
                break;                                                         \
            }                                                                  \
        if (existing < n) {                                                    \
            val_free(map->entries[existing].value);                            \
            map->entries[existing].value = (v);                                \
        } else {                                                               \
            if (n == cap) {                                                    \
                cap = cap ? cap * 2 : 4;                                       \
                map->entries = realloc(map->entries, sizeof(VMMapEntry) * cap);\
            }                                                                  \
            map->entries[n].key = strdup(k);                                   \
            map->entries[n].value = (v);                                       \
            n++;                                                               \
        }                                                                      \
    } while (0)
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            const char *key = expr->as.map_node.entries[i].key;
            VMValue *value =
                vm_execute(scope, expr->as.map_node.entries[i].value);
            if (!key) {
                /* `...src`: splice src's entries in at this position. */
                if (value->type != VAL_MAP) {
                    fprintf(stderr, "Spread source must be a map\n");
                    exit(1);
                }
                VMMap *src = value->data.map;
                for (size_t s = 0; s < src->count; s++) {
                    VMValue *copy = val_clone(src->entries[s].value);
                    VM_MAP_PUT(src->entries[s].key, copy);
                }
                val_free(value);
                continue;
            }
            VM_MAP_PUT(key, value);
        }
#undef VM_MAP_PUT
        map->count = n;
        VMValue *val = nval(VAL_MAP);
        val->data.map = map;
        return val;
    }
    case EXPR_EARRAY_IDX: {
        VMValue *array_val = vm_execute(scope, expr->as.array_idx_node.array);
        if (array_val->type != VAL_ARR) {
            fprintf(stderr, "Attempting to index a non-array value\n");
            exit(1);
        }
        if (array_val->data.arr->count == 0) {
            fprintf(stderr, "Array index out of bounds (empty array)\n");
            exit(1);
        }
        VMValue *idx_val = vm_execute(scope, expr->as.array_idx_node.idx);
        if (idx_val->type != VAL_LONG) {
            fprintf(stderr, "Array index must be a long\n");
            exit(1);
        }
        long idx = idx_val->data.l;
        long count = (long)array_val->data.arr->count;
        idx = (idx % count + count) % count; // handle negative indices
        VMValue *result = val_clone(array_val->data.arr->elements[idx]);
        val_free(array_val);
        val_free(idx_val);
        return result;
    }
    case EXPR_EARRAY_IDX_RANGE: {
        VMValue *array_val =
            vm_execute(scope, expr->as.array_idx_range_node.array);
        if (array_val->type != VAL_ARR) {
            fprintf(stderr, "Attempting to index a non-array value\n");
            exit(1);
        }
        VMValue *start_val =
            vm_execute(scope, expr->as.array_idx_range_node.start);
        VMValue *end_val = vm_execute(scope, expr->as.array_idx_range_node.end);
        if (start_val->type != VAL_LONG || end_val->type != VAL_LONG) {
            fprintf(stderr, "Array slice indices must be longs\n");
            exit(1);
        }
        long start = start_val->data.l;
        long end = end_val->data.l;
        long count = array_val->data.arr->count;

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
            VMArray *new_arr = vm_arr_alloc();
            new_arr->count = 0;
            new_arr->elements = NULL;
            VMValue *val = nval(VAL_ARR);
            val->data.arr = new_arr;
            val_free(array_val);
            val_free(start_val);
            val_free(end_val);
            return val;
        }

        VMArray *new_arr = vm_arr_alloc();
        new_arr->count = end - start;
        new_arr->elements = malloc(sizeof(VMValue *) * new_arr->count);
        for (size_t i = 0; i < new_arr->count; i++) {
            new_arr->elements[i] =
                val_clone(array_val->data.arr->elements[start + (long)i]);
        }
        VMValue *val = nval(VAL_ARR);
        val->data.arr = new_arr;
        val_free(array_val);
        val_free(start_val);
        val_free(end_val);
        return val;
    }
    case EXPR_EWHILE: {
        VMValue *last = nval(VAL_NULL);
        while (1) {
            VMValue *cond = vm_execute(scope, expr->as.while_node.cond);
            if (cond->type != VAL_BOOL) {
                fprintf(stderr, "While condition must be a boolean\n");
                exit(1);
            }
            bool c = cond->data.b;
            val_free(cond);
            if (!c) break;
            val_free(last);
            last = vm_execute(scope, expr->as.while_node.body);
            if (g_vm_returning) break; /* `return` inside the loop body */
        }
        return last;
    }
    case EXPR_EFOR: {
        VMVariableScope *for_scope = vm_scope_new(scope);
        if (expr->as.for_node.init)
            vm_execute(for_scope, expr->as.for_node.init);
        VMValue *last = nval(VAL_NULL);
        while (1) {
            if (expr->as.for_node.cond) {
                VMValue *cond = vm_execute(for_scope, expr->as.for_node.cond);
                if (cond->type != VAL_BOOL) {
                    fprintf(stderr, "For condition must be a boolean\n");
                    exit(1);
                }
                bool c = cond->data.b;
                val_free(cond);
                if (!c) break;
            }
            val_free(last);
            last = vm_execute(for_scope, expr->as.for_node.body);
            if (g_vm_returning) break; /* `return` inside the loop body */
            if (expr->as.for_node.step)
                vm_execute(for_scope, expr->as.for_node.step);
        }
        vm_scope_release(for_scope);
        return last;
    }
    case EXPR_EFOREACH: {
        VMValue *iterable = vm_execute(scope, expr->as.foreach_node.iterable);
        if (iterable->type != VAL_ARR) {
            fprintf(stderr, "foreach requires an array\n");
            exit(1);
        }
        VMVariableScope *fe_scope = vm_scope_new(scope);
        VMValue *last = nval(VAL_NULL);
        for (size_t i = 0; i < iterable->data.arr->count; i++) {
            vm_scope_set(fe_scope, expr->as.foreach_node.var_name,
                         iterable->data.arr->elements[i]);
            val_free(last);
            last = vm_execute(fe_scope, expr->as.foreach_node.body);
            if (g_vm_returning) break; /* `return` inside the loop body */
        }
        vm_scope_release(fe_scope);
        val_free(iterable);
        return last;
    }
    case EXPR_EFORRANGE: {
        VMValue *start_val = vm_execute(scope, expr->as.forrange_node.start);
        VMValue *end_val = vm_execute(scope, expr->as.forrange_node.end);
        if (start_val->type != VAL_LONG || end_val->type != VAL_LONG) {
            fprintf(stderr, "for range bounds must be longs\n");
            exit(1);
        }
        long s = start_val->data.l;
        long e = end_val->data.l;
        val_free(start_val);
        val_free(end_val);
        VMVariableScope *fr_scope = vm_scope_new(scope);
        VMValue *last = nval(VAL_NULL);
        for (long i = s; i < e; i++) {
            VMValue *iv = nval(VAL_LONG);
            iv->data.l = i;
            vm_scope_set(fr_scope, expr->as.forrange_node.var_name, iv);
            val_free(iv);
            val_free(last);
            last = vm_execute(fr_scope, expr->as.forrange_node.body);
            if (g_vm_returning) break; /* `return` inside the loop body */
        }
        vm_scope_release(fr_scope);
        return last;
    }
    case EXPR_EARRAY_ASSIGN: {
        VMValue *array_val = vm_execute(scope, expr->as.array_assign_node.array);
        VMValue *idx_val = vm_execute(scope, expr->as.array_assign_node.idx);
        /* Field/key assignment: `s.f = v` (and `m["k"] = v`) reach here as
         * a map target with a string key. Maps are reference values, so the
         * write is visible through every binding -- no write-back needed. */
        if (array_val->type == VAL_MAP) {
            if (idx_val->type != VAL_STR) {
                fprintf(stderr, "Map key must be a string\n");
                exit(1);
            }
            VMValue *value = vm_execute(scope, expr->as.array_assign_node.value);
            VMMap *m = array_val->data.map;
            int found = 0;
            for (size_t i = 0; i < m->count; i++) {
                if (strcmp(m->entries[i].key, idx_val->data.s) == 0) {
                    val_free(m->entries[i].value);
                    m->entries[i].value = value;
                    found = 1;
                    break;
                }
            }
            if (!found) {
                m->entries = realloc(m->entries, sizeof(VMMapEntry) * (m->count + 1));
                m->entries[m->count].key = strdup(idx_val->data.s);
                m->entries[m->count].value = value;
                m->count++;
            }
            val_free(array_val);
            val_free(idx_val);
            return nval(VAL_NULL);
        }
        if (array_val->type != VAL_ARR) {
            fprintf(stderr, "Array assignment target must be an array\n");
            exit(1);
        }
        if (idx_val->type != VAL_LONG) {
            fprintf(stderr, "Array index must be a long\n");
            exit(1);
        }
        long idx = idx_val->data.l;
        long count = (long)array_val->data.arr->count;
        if (count == 0) {
            fprintf(stderr, "Array index out of bounds (empty array)\n");
            exit(1);
        }
        idx = (idx % count + count) % count; // normalize negative indices
        VMValue *value = vm_execute(scope, expr->as.array_assign_node.value);
        /* Mutate the clone, then write it back to scope */
        val_free(array_val->data.arr->elements[idx]);
        array_val->data.arr->elements[idx] = value;
        /* Write modified array back if the target was a variable */
        if (expr->as.array_assign_node.array->kind == EXPR_EVAR) {
            vm_scope_set(scope, expr->as.array_assign_node.array->as.evar,
                         array_val);
        }
        val_free(array_val);
        val_free(idx_val);
        return nval(VAL_NULL);
    }
    }
    fprintf(stderr, "Unsupported expression kind: %d\n", expr->kind);
    exit(1);
}