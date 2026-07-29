#include "vm.h"
#include "ast.h"
#include "ast_debug.h"
#include "lib.h"
#include "map.h"
#include "type.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

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
        VMArray *arr = malloc(sizeof(VMArray));
        arr->count = src->data.arr->count;
        arr->elements = malloc(sizeof(VMValue *) * arr->count);
        for (size_t i = 0; i < arr->count; i++) {
            arr->elements[i] = val_clone(src->data.arr->elements[i]);
        }
        dst->data.arr = arr;
        break;
    }
    case VAL_MAP: {
        VMMap *map = malloc(sizeof(VMMap));
        map->count = src->data.map->count;
        map->entries = malloc(sizeof(VMMapEntry) * map->count);
        for (size_t i = 0; i < map->count; i++) {
            map->entries[i].key = strdup(src->data.map->entries[i].key);
            map->entries[i].value = val_clone(src->data.map->entries[i].value);
        }
        dst->data.map = map;
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
        for (size_t i = 0; i < val->data.arr->count; i++) {
            val_free(val->data.arr->elements[i]);
        }
        free(val->data.arr->elements);
        free(val->data.arr);
        break;
    }
    case VAL_MAP: {
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
    if (!scope) return NULL;
    VMValue *val = map_get(&scope->variables, name);
    if (val) return val;
    return vm_scope_get(scope->parent, name);
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
    case EXPR_EOP: {
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
    __REQUIRES_NUMERIC();                                                      \
    if (left->type == VAL_LONG && right->type == VAL_LONG) {                   \
        val->data.b = left->data.l op right->data.l;                           \
    } else {                                                                   \
        double left_val =                                                      \
            left->type == VAL_LONG ? left->data.l : left->data.f;              \
        double right_val =                                                     \
            right->type == VAL_LONG ? right->data.l : right->data.f;           \
        val->data.b = left_val op right_val;                                   \
    }                                                                          \
    val->type = VAL_BOOL;
#define __ISCALCULATION(op)                                                    \
    __REQUIRES_NUMERIC();                                                      \
    if (left->type == VAL_LONG && right->type == VAL_LONG) {                   \
        val->data.l = left->data.l op right->data.l;                           \
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
            val->data.l = left->data.l % right->data.l;
            val->type = VAL_LONG;
            break;
        }
        case O_DIV: {
            if (left->type == VAL_LONG && right->type == VAL_LONG &&
                right->data.l == 0) {
                fprintf(stderr, "Division by zero\n");
                exit(1);
            }
            __ISCALCULATION(/);
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
            VMArray *new_arr = malloc(sizeof(VMArray));
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
        vm_scope_set(scope, expr->as.declaration_node.name, val);
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
        }
        vm_scope_release(nested_scope);
        return last;
    }
    case EXPR_ECALL: {
        VMValue *callee_val = vm_execute(scope, expr->as.call_node.callee);
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
        map_set(&func_scope->variables, "self", val_clone(callee_val));
        VMValue *result = func->as.efunc.external
                              ? ((VMValue * (*)(VMVariableScope *))
                                     func->as.efunc.body)(func_scope)
                              : vm_execute(func_scope, func->as.efunc.body);
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
        VMArray *arr = malloc(sizeof(VMArray));
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
        VMMap *map = malloc(sizeof(VMMap));
        map->count = expr->as.map_node.count;
        map->entries = malloc(sizeof(VMMapEntry) * map->count);
        size_t n = 0;
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            const char *key = expr->as.map_node.entries[i].key;
            VMValue *value =
                vm_execute(scope, expr->as.map_node.entries[i].value);
            /* Duplicate keys: last value wins (overwrite in place). */
            size_t existing = n;
            for (size_t j = 0; j < n; j++) {
                if (strcmp(map->entries[j].key, key) == 0) {
                    existing = j;
                    break;
                }
            }
            if (existing < n) {
                val_free(map->entries[existing].value);
                map->entries[existing].value = value;
            } else {
                map->entries[n].key = strdup(key);
                map->entries[n].value = value;
                n++;
            }
        }
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
        bool reversed = false;
        long start = start_val->data.l;
        long end = end_val->data.l;
        long count = array_val->data.arr->count;
        // handle empty arrays
        if (count == 0) {
            VMArray *new_arr = malloc(sizeof(VMArray));
            new_arr->count = 0;
            new_arr->elements = NULL;
            VMValue *val = nval(VAL_ARR);
            val->data.arr = new_arr;
            val_free(array_val);
            val_free(start_val);
            val_free(end_val);
            return val;
        }
        // handle negative indices
        if (count <= 1 && start >= 1) {
            // return empty array coz well
            VMArray *new_arr = malloc(sizeof(VMArray));
            new_arr->count = 0;
            new_arr->elements = NULL;
            VMValue *val = nval(VAL_ARR);
            val->data.arr = new_arr;
            val_free(array_val);
            val_free(start_val);
            val_free(end_val);
            return val;
        }
        start = (start % count + count) % count;
        end = (end % count + count) % count;

        if (end < start) {
            reversed = true;
            long temp = start;
            start = end;
            end = temp;
        }
        VMArray *new_arr = malloc(sizeof(VMArray));
        new_arr->count = end - start + 1;
        new_arr->elements = malloc(sizeof(VMValue *) * new_arr->count);
        for (size_t i = 0; i < new_arr->count; i++) {
            long idx = (start + i) % count;
            new_arr->elements[i] =
                val_clone(array_val->data.arr->elements[idx]);
        }
        if (reversed) {
            // reverse the new array in place
            for (size_t i = 0; i < new_arr->count / 2; i++) {
                VMValue *temp = new_arr->elements[i];
                new_arr->elements[i] =
                    new_arr->elements[new_arr->count - 1 - i];
                new_arr->elements[new_arr->count - 1 - i] = temp;
            }
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
        }
        vm_scope_release(fr_scope);
        return last;
    }
    case EXPR_EARRAY_ASSIGN: {
        VMValue *array_val = vm_execute(scope, expr->as.array_assign_node.array);
        if (array_val->type != VAL_ARR) {
            fprintf(stderr, "Array assignment target must be an array\n");
            exit(1);
        }
        VMValue *idx_val = vm_execute(scope, expr->as.array_assign_node.idx);
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