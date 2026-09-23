#include "ast.h"
#include "list.h"
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *OPERATORS[] = {">=", "<=", "&&", "||", "==", "!=", "+", "-", "*",
                           "/",  "=",  "<",  ">",  "::", ".",  "%", NULL};

Operator operator_from_str(const char *op) {
    for (size_t i = 0; OPERATORS[i]; i++) {
        if (strcmp(op, OPERATORS[i]) == 0) { return (Operator)i; }
    }
    return -1; // invalid operator
}

const char *operator_to_str(Operator op) {
    if (op == O_NOT) { return "!"; }
    if (op < 0 || (size_t)op >= sizeof(OPERATORS) / sizeof(OPERATORS[0]) - 1) {
        return "<invalid operator>";
    }
    return OPERATORS[op];
}
// const char *TYPE_STRS[] = {"null", "long", "float", "bool", "str",
//                            "func", "arr",  "map",   NULL};
const char *KEYWORDS[] = {"let",   "const", "def",    "if",   "else",
                          "while", "for",   "return", "in",   "foreach",
                          "null",  NULL};

void ast_free(Expr *expr) {
    if (!expr) return;
    switch (expr->kind) {
    case EXPR_ELONG: break;
    case EXPR_EFLOAT: break;
    case EXPR_EBOOL: break;
    case EXPR_EVAR: free((char *)(expr->as.evar)); break;
    case EXPR_EIF:
        ast_free(expr->as.if_node.cond);
        ast_free(expr->as.if_node.then_branch);
        ast_free(expr->as.if_node.else_branch);
        break;
    case EXPR_EOP:
        ast_free(expr->as.op_node.left);
        ast_free(expr->as.op_node.right);
        break;
    case EXPR_EUNARY:
        ast_free(expr->as.unary_node.operand);
        break;
    case EXPR_ERETURN:
        ast_free(expr->as.return_value);
        break;
    case EXPR_EASSIGNMENT:
        free((char *)(expr->as.assignment_node.var_name));
        ast_free(expr->as.assignment_node.value);
        break;
    case EXPR_EDECLARATION:
        free((char *)(expr->as.declaration_node.name));
        ast_free(expr->as.declaration_node.value);
        break;
    case EXPR_EBLOCK:
        for (size_t i = 0; i < expr->as.block_node.count; i++) {
            ast_free(expr->as.block_node.exprs[i]);
        }
        free(expr->as.block_node.exprs);
        break;
    case EXPR_ECALL:
        ast_free(expr->as.call_node.callee);
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            ast_free(expr->as.call_node.args[i]);
        }
        free(expr->as.call_node.args);
        break;
    case EXPR_EFUNC:
        for (size_t i = 0; i < expr->as.efunc.param_count; i++) {
            free((char *)expr->as.efunc.param_names[i]);
        }
        list_free(expr->as.efunc.param_names);
        list_free(expr->as.efunc.param_types);
        ast_free(expr->as.efunc.body);
        break;
    case EXPR_ESTR: {
        free((char *)expr->as.estr.data);
        break;
    }
    case EXPR_EARRAY:
        for (size_t i = 0; i < expr->as.array_node.count; i++) {
            ast_free(expr->as.array_node.elements[i]);
        }
        list_free(expr->as.array_node.elements);
        break;
    case EXPR_EMAP:
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            free((char *)expr->as.map_node.entries[i].key);
            ast_free(expr->as.map_node.entries[i].value);
        }
        list_free(expr->as.map_node.entries);
        break;
    case EXPR_EARRAY_IDX:
        ast_free(expr->as.array_idx_node.array);
        ast_free(expr->as.array_idx_node.idx);
        break;
    case EXPR_EARRAY_IDX_RANGE:
        ast_free(expr->as.array_idx_range_node.array);
        ast_free(expr->as.array_idx_range_node.start);
        ast_free(expr->as.array_idx_range_node.end);
        break;
    case EXPR_EWHILE:
        ast_free(expr->as.while_node.cond);
        ast_free(expr->as.while_node.body);
        break;
    case EXPR_EFOR:
        ast_free(expr->as.for_node.init);
        ast_free(expr->as.for_node.cond);
        ast_free(expr->as.for_node.step);
        ast_free(expr->as.for_node.body);
        break;
    case EXPR_EFOREACH:
        free((char *)expr->as.foreach_node.var_name);
        ast_free(expr->as.foreach_node.iterable);
        ast_free(expr->as.foreach_node.body);
        break;
    case EXPR_EFORRANGE:
        free((char *)expr->as.forrange_node.var_name);
        ast_free(expr->as.forrange_node.start);
        ast_free(expr->as.forrange_node.end);
        ast_free(expr->as.forrange_node.body);
        break;
    case EXPR_EARRAY_ASSIGN:
        ast_free(expr->as.array_assign_node.array);
        ast_free(expr->as.array_assign_node.idx);
        ast_free(expr->as.array_assign_node.value);
        break;
    case EXPR_ENULL: break;
    }
    free(expr);
}

Expr *ast_clone(Expr *expr) {
    if (!expr) return NULL;
    Expr *copy = (Expr *)malloc(sizeof(Expr));
    copy->kind = expr->kind;
    switch (expr->kind) {
    case EXPR_ELONG: copy->as.elong = expr->as.elong; break;
    case EXPR_EFLOAT: copy->as.efloat = expr->as.efloat; break;
    case EXPR_EVAR: copy->as.evar = strdup(expr->as.evar); break;
    case EXPR_EBOOL: copy->as.ebool = expr->as.ebool; break;
    case EXPR_EIF:
        copy->as.if_node.cond = ast_clone(expr->as.if_node.cond);
        copy->as.if_node.then_branch = ast_clone(expr->as.if_node.then_branch);
        copy->as.if_node.else_branch = ast_clone(expr->as.if_node.else_branch);
        break;
    case EXPR_EOP:
        copy->as.op_node.op = expr->as.op_node.op;
        copy->as.op_node.left = ast_clone(expr->as.op_node.left);
        copy->as.op_node.right = ast_clone(expr->as.op_node.right);
        break;
    case EXPR_EUNARY:
        copy->as.unary_node.op = expr->as.unary_node.op;
        copy->as.unary_node.operand = ast_clone(expr->as.unary_node.operand);
        break;
    case EXPR_ERETURN:
        copy->as.return_value = ast_clone(expr->as.return_value);
        break;
    case EXPR_EASSIGNMENT:
        copy->as.assignment_node.var_name =
            strdup(expr->as.assignment_node.var_name);
        copy->as.assignment_node.value =
            ast_clone(expr->as.assignment_node.value);
        break;
    case EXPR_EDECLARATION:
        copy->as.declaration_node.kind = expr->as.declaration_node.kind;
        copy->as.declaration_node.name = strdup(expr->as.declaration_node.name);
        copy->as.declaration_node.value =
            ast_clone(expr->as.declaration_node.value);
        break;
    case EXPR_EBLOCK:
        copy->as.block_node.count = expr->as.block_node.count;
        copy->as.block_node.exprs =
            (Expr **)malloc(sizeof(Expr *) * expr->as.block_node.count);
        for (size_t i = 0; i < expr->as.block_node.count; i++) {
            copy->as.block_node.exprs[i] =
                ast_clone(expr->as.block_node.exprs[i]);
        }
        break;
    case EXPR_ECALL:
        copy->as.call_node.callee = ast_clone(expr->as.call_node.callee);
        copy->as.call_node.arg_count = expr->as.call_node.arg_count;
        copy->as.call_node.args =
            (Expr **)malloc(sizeof(Expr *) * expr->as.call_node.arg_count);
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            copy->as.call_node.args[i] = ast_clone(expr->as.call_node.args[i]);
        }
        break;
    case EXPR_EFUNC:
        copy->as.efunc.param_count = expr->as.efunc.param_count;
        copy->as.efunc.param_names =
            (char **)malloc(sizeof(char *) * expr->as.efunc.param_count);
        for (size_t i = 0; i < expr->as.efunc.param_count; i++) {
            copy->as.efunc.param_names[i] =
                strdup(expr->as.efunc.param_names[i]);
        }
        copy->as.efunc.body = ast_clone(expr->as.efunc.body);
        break;
    case EXPR_ESTR: copy->as.estr.data = strdup(expr->as.estr.data); break;
    case EXPR_EARRAY:
        copy->as.array_node.count = expr->as.array_node.count;
        copy->as.array_node.elements =
            (Expr **)malloc(sizeof(Expr *) * expr->as.array_node.count);
        for (size_t i = 0; i < expr->as.array_node.count; i++) {
            copy->as.array_node.elements[i] =
                ast_clone(expr->as.array_node.elements[i]);
        }
        break;
    case EXPR_EMAP:
        copy->as.map_node.count = expr->as.map_node.count;
        copy->as.map_node.entries =
            (EMapEntry *)malloc(sizeof(EMapEntry) * expr->as.map_node.count);
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            copy->as.map_node.entries[i] = (EMapEntry){
                /* NULL key = spread entry (`...src`) */
                .key = expr->as.map_node.entries[i].key
                           ? strdup(expr->as.map_node.entries[i].key)
                           : NULL,
                .value = ast_clone(expr->as.map_node.entries[i].value),
            };
        }
        break;
    case EXPR_EARRAY_IDX:
        copy->as.array_idx_node.array =
            ast_clone(expr->as.array_idx_node.array);
        copy->as.array_idx_node.idx = ast_clone(expr->as.array_idx_node.idx);
        break;
    case EXPR_EARRAY_IDX_RANGE:
        copy->as.array_idx_range_node.array =
            ast_clone(expr->as.array_idx_range_node.array);
        copy->as.array_idx_range_node.start =
            ast_clone(expr->as.array_idx_range_node.start);
        copy->as.array_idx_range_node.end =
            ast_clone(expr->as.array_idx_range_node.end);
        break;
    case EXPR_EWHILE:
        copy->as.while_node.cond = ast_clone(expr->as.while_node.cond);
        copy->as.while_node.body = ast_clone(expr->as.while_node.body);
        break;
    case EXPR_EFOR:
        copy->as.for_node.init = ast_clone(expr->as.for_node.init);
        copy->as.for_node.cond = ast_clone(expr->as.for_node.cond);
        copy->as.for_node.step = ast_clone(expr->as.for_node.step);
        copy->as.for_node.body = ast_clone(expr->as.for_node.body);
        break;
    case EXPR_EFOREACH:
        copy->as.foreach_node.var_name =
            strdup(expr->as.foreach_node.var_name);
        copy->as.foreach_node.iterable =
            ast_clone(expr->as.foreach_node.iterable);
        copy->as.foreach_node.body = ast_clone(expr->as.foreach_node.body);
        break;
    case EXPR_EFORRANGE:
        copy->as.forrange_node.var_name =
            strdup(expr->as.forrange_node.var_name);
        copy->as.forrange_node.start =
            ast_clone(expr->as.forrange_node.start);
        copy->as.forrange_node.end = ast_clone(expr->as.forrange_node.end);
        copy->as.forrange_node.body = ast_clone(expr->as.forrange_node.body);
        break;
    case EXPR_EARRAY_ASSIGN:
        copy->as.array_assign_node.array =
            ast_clone(expr->as.array_assign_node.array);
        copy->as.array_assign_node.idx =
            ast_clone(expr->as.array_assign_node.idx);
        copy->as.array_assign_node.value =
            ast_clone(expr->as.array_assign_node.value);
        break;
    case EXPR_ENULL: break;
    }
    return copy;
}