#include "typecheck.h"
#include "ast.h"
#include "ast_debug.h"
#include "map.h"
#include "type.h"
#include <stddef.h>
#include <stdio.h>

#define TC_OK(T)                                                               \
    ((typecheck_result_t){                                                     \
        .is_ok = 1, .type = (T), .error_message = NULL, .error_expr = NULL})
#define TC_ERR(M, E)                                                           \
    ((typecheck_result_t){.is_ok = 0,                                          \
                          .type = _TYPE_INFERRED,                              \
                          .error_message = (M),                                \
                          .error_expr = (E)})

void print_scope(TCVarTypeScope *scope) {
    if (!scope) return;
    printf("Scope at %p:\n", (void *)scope);
    for (size_t i = 0; i < scope->variables.len; i++) {
        char *name = scope->variables.items[i].key;
        type_t *type = scope->variables.items[i].value;
        printf("  %s: %s\n", name, type_t_to_str(type));
    }
    print_scope(scope->parent);
}

type_t *tc_scope_get(TCVarTypeScope *scope, const char *name) {
    if (!scope) return NULL;
    type_t *type = map_get(&scope->variables, name);
    if (type) return type;
    return tc_scope_get(scope->parent, name);
}
void tc_scope_set(TCVarTypeScope *scope, const char *name, type_t *value) {
    map_set(&scope->variables, name, value);
}

typecheck_result_t tc_expr(Expr *expr, TCVarTypeScope *scope);

typecheck_result_t tc_function(Expr *expr, TCVarTypeScope *scope) {
    TCVarTypeScope func_scope = {0};
    map_init(&func_scope.variables);
    func_scope.parent = scope;
    for (size_t i = 0; i < expr->as.efunc.param_count; i++) {
        tc_scope_set(&func_scope, expr->as.efunc.param_names[i],
                     expr->as.efunc.param_types[i]);
    }
    type_t *func_type = tc_make_t(VAL_FUNC);
    type_t *return_type = expr->as.efunc.return_type;
    func_type->as.func.param_count = expr->as.efunc.param_count;
    func_type->as.func.param_types = expr->as.efunc.param_types;
    func_type->as.func.return_type = expr->as.efunc.return_type;

    tc_scope_set(&func_scope, "self", func_type); // for recursive functions
    typecheck_result_t result = tc_expr(expr->as.efunc.body, &func_scope);
    map_free(&func_scope.variables);
    if (!result.is_ok) { return result; }
    if (return_type->base != _VAL_INFERRED &&
        return_type->base != result.type->base) {
        return TC_ERR("Return type does not match function signature", expr);
    }

    func_type->as.func.param_count = expr->as.efunc.param_count;
    func_type->as.func.param_types = expr->as.efunc.param_types;
    func_type->as.func.return_type = result.type;

    return TC_OK(func_type);
}

typecheck_result_t tc_declaration(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t vres = tc_expr(expr->as.declaration_node.value, scope);
    if (!vres.is_ok) { return vres; }
    tc_scope_set(scope, expr->as.declaration_node.name, vres.type);
    return TC_OK(vres.type);
}

typecheck_result_t tc_if(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t cond_res = tc_expr(expr->as.if_node.cond, scope);
    if (!cond_res.is_ok) { return cond_res; }
    if (cond_res.type->base != VAL_BOOL) {
        return TC_ERR("Condition of if expression must be a boolean", expr);
    }
    typecheck_result_t then_res = tc_expr(expr->as.if_node.then_branch, scope);
    if (!then_res.is_ok) { return then_res; }
    if (!expr->as.if_node.else_branch) {
        return TC_OK(TYPE_NULL);
    }
    typecheck_result_t else_res = tc_expr(expr->as.if_node.else_branch, scope);
    if (!else_res.is_ok) { return else_res; }
    if (then_res.type->base != else_res.type->base) {
        return TC_OK(TYPE_NULL); // if type mismatch, we just return null type
    }
    return TC_OK(then_res.type);
}

typecheck_result_t tc_binary_op(Expr *expr, TCVarTypeScope *scope) {
    if (expr->as.op_node.op == O_ASSIGN) {
        // binary ops should never have assignment operator, it should be
        // handled as a EAssignment
        return TC_ERR("Unexpected assignment operator in expression", expr);
    }
    if (expr->as.op_node.op == O_DOT) {
        // seperate logic for obj.key
        typecheck_result_t left_res = tc_expr(expr->as.op_node.left, scope);
        if (!left_res.is_ok) { return left_res; }
        if (left_res.type->base != VAL_MAP) {
            return TC_ERR("Left-hand side of dot operator must be a map",
                          expr->as.op_node.left);
        }
        // right side must be a identifier
        if (expr->as.op_node.right->kind != EXPR_EVAR) {
            return TC_ERR(
                "Right-hand side of dot operator must be an identifier",
                expr->as.op_node.right);
        }
        const char *key = expr->as.op_node.right->as.evar;
        type_t *value_type = NULL;
        for (size_t i = 0; i < left_res.type->as.map.count; i++) {
            if (strcmp(left_res.type->as.map.entries[i].key, key) == 0) {
                value_type = left_res.type->as.map.entries[i].value;
                break;
            }
        }
        if (!value_type) {
            return TC_ERR("Key not found in map", expr->as.op_node.right);
        }
        return TC_OK(value_type);
    }
    // these ops only work on numbers, and should only produce numbers, may be
    // int or float, we allow mix use, which would result in float

    bool input_numeric =
        expr->as.op_node.op == O_ADD || expr->as.op_node.op == O_SUB ||
        expr->as.op_node.op == O_MUL || expr->as.op_node.op == O_DIV ||
        expr->as.op_node.op == O_LT || expr->as.op_node.op == O_GT ||
        expr->as.op_node.op == O_LTE || expr->as.op_node.op == O_GTE ||
        expr->as.op_node.op == O_MOD;

    // these ops can work on any two values of the same type or if one of them
    // is null
    bool input_bool =
        expr->as.op_node.op == O_AND || expr->as.op_node.op == O_OR;
    bool input_types_match_or_one_is_null =
        expr->as.op_node.op == O_EQ || expr->as.op_node.op == O_NEQ;

    bool output_numeric =
        expr->as.op_node.op == O_ADD || expr->as.op_node.op == O_SUB ||
        expr->as.op_node.op == O_MUL || expr->as.op_node.op == O_DIV ||
        expr->as.op_node.op == O_MOD;
    bool output_bool =
        expr->as.op_node.op == O_AND || expr->as.op_node.op == O_OR ||
        expr->as.op_node.op == O_LT || expr->as.op_node.op == O_GT ||
        expr->as.op_node.op == O_LTE || expr->as.op_node.op == O_GTE ||
        expr->as.op_node.op == O_EQ || expr->as.op_node.op == O_NEQ;

    typecheck_result_t left_res = tc_expr(expr->as.op_node.left, scope);
    if (!left_res.is_ok) { return left_res; }
    typecheck_result_t right_res = tc_expr(expr->as.op_node.right, scope);
    if (!right_res.is_ok) { return right_res; }

    // special case, if any one side is string, this is string concat operator
    if ((left_res.type->base == VAL_STR || right_res.type->base == VAL_STR) &&
        expr->as.op_node.op == O_ADD) {
        printf("[typecheck warning] implicit string concatenation\n");
        ast_print_code(stdout, expr, 0);
        printf("\n\n");
        return TC_OK(TYPE_STR);
    }

    if (input_bool &&
        (left_res.type->base != VAL_BOOL || right_res.type->base != VAL_BOOL)) {
        return TC_ERR("Operands of boolean operator must be boolean", expr);
    }
    bool ordering_op =
        expr->as.op_node.op == O_LT || expr->as.op_node.op == O_GT ||
        expr->as.op_node.op == O_LTE || expr->as.op_node.op == O_GTE;
    /* str < str is lexicographic ordering, not arithmetic. */
    bool both_strings =
        left_res.type->base == VAL_STR && right_res.type->base == VAL_STR;
    if (ordering_op && both_strings) { return TC_OK(TYPE_BOOL); }

    if (input_numeric && (!(left_res.type->base == VAL_LONG ||
                            left_res.type->base == VAL_FLOAT) ||
                          !(right_res.type->base == VAL_LONG ||
                            right_res.type->base == VAL_FLOAT))) {
        printf("left type: %s ", type_t_to_str(left_res.type));
        printf("right type: %s\n", type_t_to_str(right_res.type));
        printf("left base: %d, right base: %d\n", left_res.type->base,
               right_res.type->base);
        return TC_ERR("Operands of numeric operator must be numeric", expr);
    }
    if (input_types_match_or_one_is_null &&
        !((left_res.type->base == right_res.type->base) ||
          left_res.type->base == VAL_NULL ||
          right_res.type->base == VAL_NULL)) {
        printf("left base: %d, right base: %d\n", left_res.type->base,
               right_res.type->base);
        printf("left type: %s, right type: %s\n", type_t_to_str(left_res.type),
               type_t_to_str(right_res.type));
        ast_print_code(stdout, expr->as.op_node.left, 0);
        printf("\n");
        ast_print_code(stdout, expr->as.op_node.right, 0);
        printf("\n");
        return TC_ERR(
            "Operands of equality operator must be of the same type or "
            "one of them must be null",
            expr);
    }
    if (output_numeric) {
        if (left_res.type->base == VAL_FLOAT ||
            right_res.type->base == VAL_FLOAT) {
            return TC_OK(TYPE_FLOAT);
        }
        return TC_OK(TYPE_LONG);
    }
    if (output_bool) { return TC_OK(TYPE_BOOL); }
    return TC_OK(TYPE_NULL); // should never reach here
}

typecheck_result_t tc_assignment(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t value_res =
        tc_expr(expr->as.assignment_node.value, scope);
    if (!value_res.is_ok) { return value_res; }
    type_t *var_type = tc_scope_get(scope, expr->as.assignment_node.var_name);
    if (!var_type) { return TC_ERR("Undefined variable in assignment", expr); }
    if (var_type->base != value_res.type->base) {
        return TC_ERR("Type mismatch in assignment", expr);
    }
    tc_scope_set(scope, expr->as.assignment_node.var_name, value_res.type);
    return TC_OK(value_res.type);
}

typecheck_result_t tc_call(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t callee_res = tc_expr(expr->as.call_node.callee, scope);
    if (!callee_res.is_ok) { return callee_res; }
    if (callee_res.type->base != VAL_FUNC) {
        return TC_ERR("Attempting to call a non-function value",
                      expr->as.call_node.callee);
    }
    type_t *func_type = callee_res.type;
    if (func_type->base != VAL_FUNC) {
        return TC_ERR("Attempting to call a non-function value",
                      expr->as.call_node.callee);
    }
    if (func_type->as.func.param_count != expr->as.call_node.arg_count) {
        return TC_ERR("Argument count mismatch in function call", expr);
    }
    for (size_t i = 0; i < func_type->as.func.param_count; i++) {
        typecheck_result_t arg_res = tc_expr(expr->as.call_node.args[i], scope);
        if (!arg_res.is_ok) { return arg_res; }
        if (func_type->as.func.param_types[i]->base != _VAL_INFERRED &&
            arg_res.type->base != func_type->as.func.param_types[i]->base) {
            /* Every other TC_ERR message is a string literal and nothing
             * frees error_message, so this formatted one lives in a static
             * buffer. A local array would dangle: the result travels up to
             * main and is printed long after tc_call returns
             * (ASan: stack-use-after-return). Errors propagate straight to
             * the top and are reported once, so one buffer is enough. */
            static char error_msg[256];
            char expected_type_str[64];
            char actual_type_str[64];
            char callee_str[64];
            type_t_to_buf(func_type, callee_str, sizeof(callee_str));
            type_t_to_buf(func_type->as.func.param_types[i], expected_type_str,
                          sizeof(expected_type_str));
            type_t_to_buf(arg_res.type, actual_type_str,
                          sizeof(actual_type_str));
            snprintf(error_msg, sizeof(error_msg),
                     "Argument type mismatch in function call to %s: expected "
                     "%s, got "
                     "%s",
                     callee_str, expected_type_str, actual_type_str);
            return TC_ERR(error_msg, expr->as.call_node.args[i]);
        }
    }
    return TC_OK(func_type->as.func.return_type);
}

typecheck_result_t tc_block(Expr *expr, TCVarTypeScope *scope) {
    TCVarTypeScope nested_scope;
    map_init(&nested_scope.variables);
    nested_scope.parent = scope;
    typecheck_result_t last_res = TC_OK(TYPE_NULL);
    for (size_t i = 0; i < expr->as.block_node.count; i++) {
        last_res = tc_expr(expr->as.block_node.exprs[i], &nested_scope);
        if (!last_res.is_ok) break;
    }
    map_free(&nested_scope.variables);
    return last_res;
}

typecheck_result_t tc_array(Expr *expr, TCVarTypeScope *scope) {
    // just need to make sure all elements have the same type, and return an
    // array type of that type
    if (expr->as.array_node.count == 0) { return TC_OK(_TYPE_INFERRED_ARRAY); }
    type_t *first_elem_type = NULL;
    for (size_t i = 0; i < expr->as.array_node.count; i++) {
        typecheck_result_t elem_res =
            tc_expr(expr->as.array_node.elements[i], scope);
        if (!elem_res.is_ok) { return elem_res; }
        if (i == 0) {
            first_elem_type = elem_res.type;
            continue;
        }
        if (elem_res.type->base != first_elem_type->base) {
            return TC_ERR("Array elements must have the same type",
                          expr->as.array_node.elements[i]);
        }
    }
    type_t *arr_type = tc_make_t(VAL_ARR);
    arr_type->as.array.element_type = first_elem_type;
    return TC_OK(arr_type);
}

typecheck_result_t tc_map(Expr *expr, TCVarTypeScope *scope) {
    // no restrictions on map types, but must compute the actual type
    type_t *map_type = tc_make_t(VAL_MAP);
    map_type->as.map.count = expr->as.map_node.count;
    map_type->as.map.entries = (type_map_entry_t *)malloc(
        sizeof(type_map_entry_t) * expr->as.map_node.count);

    size_t n = 0;
    for (size_t i = 0; i < expr->as.map_node.count; i++) {
        EMapEntry entry = expr->as.map_node.entries[i];
        typecheck_result_t value_res = tc_expr(entry.value, scope);
        if (!value_res.is_ok) {
            free(map_type->as.map.entries);
            return value_res;
        }
        /* Spread (`...src`, NULL key): the source's keys are only known at
         * runtime, so the literal's static shape is whatever the explicit
         * keys contribute. */
        if (!entry.key) continue;
        if (strlen(entry.key) >= 32) {
            free(map_type->as.map.entries);
            return TC_ERR("Map entry key exceeds maximum length of 32", expr);
        }
        map_type->as.map.entries[n].key[0] = 0;
        strncpy(map_type->as.map.entries[n].key, entry.key, 32);
        map_type->as.map.entries[n].value = value_res.type;
        n++;
    }
    map_type->as.map.count = n;
    return TC_OK(map_type);
}

typecheck_result_t tc_array_idx(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t array_res =
        tc_expr(expr->as.array_idx_node.array, scope);
    if (!array_res.is_ok) { return array_res; }
    if (array_res.type->base != VAL_ARR) {
        return TC_ERR("Attempting to index a non-array value", expr);
    }
    typecheck_result_t idx_res = tc_expr(expr->as.array_idx_node.idx, scope);
    if (!idx_res.is_ok) { return idx_res; }
    if (idx_res.type->base != VAL_LONG) {
        return TC_ERR("Array index must be a long integer", expr);
    }
    return TC_OK(array_res.type->as.array.element_type);
}

typecheck_result_t tc_array_idx_range(Expr *expr, TCVarTypeScope *scope) {
    typecheck_result_t array_res =
        tc_expr(expr->as.array_idx_range_node.array, scope);
    if (!array_res.is_ok) { return array_res; }
    if (array_res.type->base != VAL_ARR) {
        return TC_ERR("Attempting to index a non-array value", expr);
    }
    typecheck_result_t start_res =
        tc_expr(expr->as.array_idx_range_node.start, scope);
    if (!start_res.is_ok) { return start_res; }
    if (start_res.type->base != VAL_LONG) {
        return TC_ERR("Array slice start index must be a long integer", expr);
    }
    typecheck_result_t end_res =
        tc_expr(expr->as.array_idx_range_node.end, scope);
    if (!end_res.is_ok) { return end_res; }
    if (end_res.type->base != VAL_LONG) {
        return TC_ERR("Array slice end index must be a long integer", expr);
    }
    // we allow negative indices, which means counting from the end of the array
    return TC_OK(array_res.type);
}

typecheck_result_t tc_expr(Expr *expr, TCVarTypeScope *scope) {
    switch (expr->kind) {
    case EXPR_ELONG: return TC_OK(TYPE_LONG);
    case EXPR_EFLOAT: return TC_OK(TYPE_FLOAT);
    case EXPR_EBOOL: return TC_OK(TYPE_BOOL);
    case EXPR_ENULL: return TC_OK(TYPE_NULL);
    case EXPR_ESTR: return TC_OK(TYPE_STR);
    case EXPR_EFUNC: return tc_function(expr, scope);
    case EXPR_EVAR: {
        type_t *var_type = tc_scope_get(scope, expr->as.evar);
        if (!var_type) { return TC_ERR("Undefined variable", expr); }
        return TC_OK(var_type);
    }
    case EXPR_EIF: return tc_if(expr, scope);
    case EXPR_EUNARY: {
        typecheck_result_t operand_res = tc_expr(expr->as.unary_node.operand, scope);
        if (!operand_res.is_ok) return operand_res;
        if (operand_res.type->base != VAL_BOOL)
            return TC_ERR("Operand of '!' must be boolean", expr);
        return TC_OK(TYPE_BOOL);
    }
    case EXPR_ERETURN: {
        /* The returned value's type is the function's result type; the
         * checker is advisory here and simply checks the operand. */
        if (!expr->as.return_value) return TC_OK(TYPE_NULL);
        return tc_expr(expr->as.return_value, scope);
    }
    case EXPR_EOP: return tc_binary_op(expr, scope);
    case EXPR_EASSIGNMENT: return tc_assignment(expr, scope);
    case EXPR_EDECLARATION: return tc_declaration(expr, scope);
    case EXPR_ECALL: return tc_call(expr, scope);
    case EXPR_EBLOCK: return tc_block(expr, scope);
    case EXPR_EARRAY: return tc_array(expr, scope);
    case EXPR_EMAP: return tc_map(expr, scope);
    case EXPR_EARRAY_IDX: return tc_array_idx(expr, scope);
    case EXPR_EARRAY_IDX_RANGE: return tc_array_idx_range(expr, scope);
    case EXPR_EWHILE: {
        typecheck_result_t cond_res = tc_expr(expr->as.while_node.cond, scope);
        if (!cond_res.is_ok) return cond_res;
        if (cond_res.type->base != VAL_BOOL)
            return TC_ERR("While condition must be boolean", expr);
        return tc_expr(expr->as.while_node.body, scope);
    }
    case EXPR_EFOR: {
        TCVarTypeScope for_scope = {0};
        map_init(&for_scope.variables);
        for_scope.parent = scope;
        typecheck_result_t r = TC_OK(TYPE_NULL);
        if (expr->as.for_node.init) {
            r = tc_expr(expr->as.for_node.init, &for_scope);
            if (!r.is_ok) { map_free(&for_scope.variables); return r; }
        }
        if (expr->as.for_node.cond) {
            r = tc_expr(expr->as.for_node.cond, &for_scope);
            if (!r.is_ok) { map_free(&for_scope.variables); return r; }
            if (r.type->base != VAL_BOOL) {
                map_free(&for_scope.variables);
                return TC_ERR("For condition must be boolean", expr);
            }
        }
        if (expr->as.for_node.step) {
            r = tc_expr(expr->as.for_node.step, &for_scope);
            if (!r.is_ok) { map_free(&for_scope.variables); return r; }
        }
        r = tc_expr(expr->as.for_node.body, &for_scope);
        map_free(&for_scope.variables);
        return r;
    }
    case EXPR_EFOREACH: {
        typecheck_result_t iter_res =
            tc_expr(expr->as.foreach_node.iterable, scope);
        if (!iter_res.is_ok) return iter_res;
        if (iter_res.type->base != VAL_ARR)
            return TC_ERR("foreach requires an array", expr);
        TCVarTypeScope fe_scope = {0};
        map_init(&fe_scope.variables);
        fe_scope.parent = scope;
        tc_scope_set(&fe_scope, expr->as.foreach_node.var_name,
                     iter_res.type->as.array.element_type);
        typecheck_result_t r = tc_expr(expr->as.foreach_node.body, &fe_scope);
        map_free(&fe_scope.variables);
        return r;
    }
    case EXPR_EFORRANGE: {
        typecheck_result_t s = tc_expr(expr->as.forrange_node.start, scope);
        if (!s.is_ok) return s;
        typecheck_result_t e = tc_expr(expr->as.forrange_node.end, scope);
        if (!e.is_ok) return e;
        if (s.type->base != VAL_LONG || e.type->base != VAL_LONG)
            return TC_ERR("for range bounds must be longs", expr);
        TCVarTypeScope fr_scope = {0};
        map_init(&fr_scope.variables);
        fr_scope.parent = scope;
        tc_scope_set(&fr_scope, expr->as.forrange_node.var_name, TYPE_LONG);
        typecheck_result_t r = tc_expr(expr->as.forrange_node.body, &fr_scope);
        map_free(&fr_scope.variables);
        return r;
    }
    case EXPR_EARRAY_ASSIGN: {
        typecheck_result_t arr_res =
            tc_expr(expr->as.array_assign_node.array, scope);
        if (!arr_res.is_ok) return arr_res;
        if (arr_res.type->base != VAL_ARR)
            return TC_ERR("Array assignment target must be an array", expr);
        typecheck_result_t idx_res =
            tc_expr(expr->as.array_assign_node.idx, scope);
        if (!idx_res.is_ok) return idx_res;
        if (idx_res.type->base != VAL_LONG)
            return TC_ERR("Array index must be a long", expr);
        return tc_expr(expr->as.array_assign_node.value, scope);
    }
    }
    // assume typecheck ok
    return TC_OK(TYPE_NULL);
}