#include "ast_debug.h"
#include "ast.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define ANSI_RESET "\x1b[0m"
#define ANSI_DIM "\x1b[2m"
#define ANSI_BOLD "\x1b[1m"
#define ANSI_RED "\x1b[31m"
#define ANSI_GREEN "\x1b[32m"
#define ANSI_YELLOW "\x1b[33m"
#define ANSI_BLUE "\x1b[34m"
#define ANSI_MAGENTA "\x1b[35m"
#define ANSI_CYAN "\x1b[36m"

static void ast_indent(int indent) {
    for (int i = 0; i < indent; i++) { printf("  "); }
}

char *escape_str(const char *s) {
    if (!s) return strdup("NULL");
    size_t len = 0;
    char *escaped = NULL;

    for (size_t i = 0; s[i]; i++) {
        char c = s[i];
        if (c == '\n' || c == '\t' || c == '\r' || c == '\\' || c == '\"') {
            len += 2; // will be replaced by two characters
        } else if ((unsigned char)c < 32 || (unsigned char)c > 126) {
            len += 4; // will be replaced by \xHH
        } else {
            len += 1; // regular character
        }
    }

    escaped = malloc(len + 1);
    size_t pos = 0;

    for (size_t i = 0; s[i]; i++) {
        char c = s[i];
        if (c == '\n') {
            escaped[pos++] = '\\';
            escaped[pos++] = 'n';
        } else if (c == '\t') {
            escaped[pos++] = '\\';
            escaped[pos++] = 't';
        } else if (c == '\r') {
            escaped[pos++] = '\\';
            escaped[pos++] = 'r';
        } else if (c == '\\') {
            escaped[pos++] = '\\';
            escaped[pos++] = '\\';
        } else if (c == '\"') {
            escaped[pos++] = '\\';
            escaped[pos++] = '\"';
        } else if ((unsigned char)c < 32 || (unsigned char)c > 126) {
            sprintf(escaped + pos, "\\x%02X", (unsigned char)c);
            pos += 4;
        } else {
            escaped[pos++] = c;
        }
    }
    escaped[pos] = '\0';
    return escaped;
}

void print_escaped(const char *s) {
    char *escaped = escape_str(s);
    printf("\"%s\"", escaped);
    free(escaped);
}

static const char *bool_str(int v) { return v ? "true" : "false"; }

static const char *decl_kind_str(DeclarationKind kind) {
    switch (kind) {
    case DECL_LET: return "let";
    case DECL_CONST: return "const";
    case DECL_FUNC: return "def";
    }
    return "unknown";
}

void ast_walk(Expr *expr, int indent);

static void ast_walk_labeled(const char *label, Expr *expr, int indent) {
    ast_indent(indent);
    printf(ANSI_DIM "%s" ANSI_RESET "\n", label);
    ast_walk(expr, indent + 1);
}

static void ast_walk_block_items(Expr **exprs, size_t count, int indent) {
    for (size_t i = 0; i < count; i++) {
        ast_indent(indent);
        printf(ANSI_DIM "[%zu]" ANSI_RESET "\n", i);
        ast_walk(exprs[i], indent + 1);
    }
}

void ast_walk(Expr *expr, int indent) {
    if (!expr) {
        ast_indent(indent);
        printf(ANSI_RED "NULL" ANSI_RESET "\n");
        return;
    }

    ast_indent(indent);

    switch (expr->kind) {
    case EXPR_ELONG:
        printf(ANSI_CYAN "ELong" ANSI_RESET "  " ANSI_DIM
                         "value=" ANSI_RESET ANSI_BOLD "%ld" ANSI_RESET "\n",
               expr->as.elong);
        break;
    case EXPR_EFLOAT:
        printf(ANSI_CYAN "EFloat" ANSI_RESET "  " ANSI_DIM
                         "value=" ANSI_RESET ANSI_BOLD "%f" ANSI_RESET "\n",
               expr->as.efloat);
        break;

    case EXPR_EVAR:
        printf(ANSI_GREEN "EIdentifier" ANSI_RESET "  " ANSI_DIM
                          "name=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
               expr->as.evar);
        break;

    case EXPR_EBOOL:
        printf(ANSI_YELLOW "EBool" ANSI_RESET "  " ANSI_DIM
                           "value=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
               bool_str(expr->as.ebool));
        break;

    case EXPR_EUNARY:
        printf(ANSI_MAGENTA "EUnary" ANSI_RESET "  " ANSI_DIM
                            "op=" ANSI_RESET ANSI_BOLD "'%s'" ANSI_RESET "\n",
               operator_to_str(expr->as.unary_node.op));
        ast_walk_labeled("operand:", expr->as.unary_node.operand, indent + 1);
        break;

    case EXPR_ERETURN:
        printf(ANSI_MAGENTA "EReturn" ANSI_RESET "\n");
        if (expr->as.return_value)
            ast_walk_labeled("value:", expr->as.return_value, indent + 1);
        break;

    case EXPR_EOP:
        printf(ANSI_MAGENTA "EOp" ANSI_RESET "  " ANSI_DIM
                            "op=" ANSI_RESET ANSI_BOLD "'%s'" ANSI_RESET "\n",
               operator_to_str(expr->as.op_node.op));
        ast_walk_labeled("left:", expr->as.op_node.left, indent + 1);
        ast_walk_labeled("right:", expr->as.op_node.right, indent + 1);
        break;

    case EXPR_EASSIGNMENT:
        printf(ANSI_BLUE "EAssignment" ANSI_RESET "  " ANSI_DIM
                         "name=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
               expr->as.assignment_node.var_name);
        ast_walk_labeled("value:", expr->as.assignment_node.value, indent + 1);
        break;

    case EXPR_EDECLARATION:
        printf(ANSI_BLUE "EDeclaration" ANSI_RESET "  " ANSI_DIM
                         "kind=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET
                         "  " ANSI_DIM "name=" ANSI_RESET ANSI_BOLD
                         "%s" ANSI_RESET "\n",
               decl_kind_str(expr->as.declaration_node.kind),
               expr->as.declaration_node.name);
        ast_walk_labeled("value:", expr->as.declaration_node.value, indent + 1);
        break;

    case EXPR_EIF:
        printf(ANSI_RED "EIf" ANSI_RESET "\n");
        ast_walk_labeled("cond:", expr->as.if_node.cond, indent + 1);
        ast_walk_labeled("then:", expr->as.if_node.then_branch, indent + 1);
        if (expr->as.if_node.else_branch) {
            ast_walk_labeled("else:", expr->as.if_node.else_branch, indent + 1);
        }
        break;

    case EXPR_EBLOCK:
        printf(ANSI_BOLD "EBlock" ANSI_RESET "  " ANSI_DIM
                         "count=%zu" ANSI_RESET "\n",
               expr->as.block_node.count);
        if (expr->as.block_node.count == 0) {
            ast_indent(indent + 1);
            printf(ANSI_DIM "(empty)" ANSI_RESET "\n");
        } else {
            ast_walk_block_items(expr->as.block_node.exprs,
                                 expr->as.block_node.count, indent + 1);
        }
        break;
    case EXPR_ECALL:
        printf(ANSI_BLUE "ECall" ANSI_RESET "\n");
        ast_walk_labeled("callee:", expr->as.call_node.callee, indent + 1);
        ast_indent(indent + 1);
        printf(ANSI_DIM "args (count=%zu):" ANSI_RESET "\n",
               expr->as.call_node.arg_count);
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            ast_walk_labeled("arg:", expr->as.call_node.args[i], indent + 2);
        }
        break;
    case EXPR_EFUNC:
        printf(ANSI_BLUE "EFunc" ANSI_RESET "  " ANSI_DIM
                         "param_count=%zu return_type=%s" ANSI_RESET "\n",
               expr->as.efunc.param_count,
               type_t_to_str(expr->as.efunc.return_type));
        for (size_t i = 0; i < expr->as.efunc.param_count; i++) {
            ast_indent(indent + 1);
            printf(ANSI_DIM "param_name=" ANSI_RESET ANSI_BOLD
                            "%s" ANSI_RESET ANSI_DIM
                            " type=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
                   expr->as.efunc.param_names[i],
                   type_t_to_str(expr->as.efunc.param_types[i]));
        }
        ast_walk_labeled("body:", expr->as.efunc.body, indent + 1);
        break;
    case EXPR_ESTR:
        printf(ANSI_CYAN "EStr" ANSI_RESET "  " ANSI_DIM "value=" ANSI_RESET);
        char *escaped = escape_str(expr->as.estr.data);
        printf(ANSI_BOLD "\"%s\"" ANSI_RESET "\n", escaped);
        free(escaped);
        break;
    case EXPR_EARRAY:
        printf(ANSI_CYAN "EArray" ANSI_RESET "  " ANSI_DIM
                         "count=%zu" ANSI_RESET "\n",
               expr->as.array_node.count);
        if (expr->as.array_node.count == 0) {
            ast_indent(indent + 1);
            printf(ANSI_DIM "(empty)" ANSI_RESET "\n");
        } else {
            ast_walk_block_items(expr->as.array_node.elements,
                                 expr->as.array_node.count, indent + 1);
        }
        break;
    case EXPR_EMAP:
        printf(ANSI_CYAN "EMap" ANSI_RESET "  " ANSI_DIM "count=%zu" ANSI_RESET
                         "\n",
               expr->as.map_node.count);
        if (expr->as.map_node.count == 0) {
            ast_indent(indent + 1);
            printf(ANSI_DIM "(empty)" ANSI_RESET "\n");
        } else {
            for (size_t i = 0; i < expr->as.map_node.count; i++) {
                ast_indent(indent + 1);
                if (!expr->as.map_node.entries[i].key) {
                    printf(ANSI_DIM "spread" ANSI_RESET "\n");
                    ast_walk_labeled("source:",
                                     expr->as.map_node.entries[i].value,
                                     indent + 2);
                    continue;
                }
                char *escaped_key =
                    escape_str(expr->as.map_node.entries[i].key);
                printf(ANSI_DIM "key=" ANSI_RESET ANSI_BOLD "\"%s\"" ANSI_RESET
                                "\n",
                       escaped_key);
                free(escaped_key);
                ast_walk_labeled("value:", expr->as.map_node.entries[i].value,
                                 indent + 2);
            }
        }
        break;
    case EXPR_EARRAY_IDX:
        printf(ANSI_CYAN "EArrayIdx" ANSI_RESET "\n");
        ast_walk_labeled("array:", expr->as.array_idx_node.array, indent + 1);
        ast_walk_labeled("idx:", expr->as.array_idx_node.idx, indent + 1);
        break;
    case EXPR_EARRAY_IDX_RANGE:
        printf(ANSI_CYAN "EArrayIdxRange" ANSI_RESET "\n");
        ast_walk_labeled("array:", expr->as.array_idx_range_node.array,
                         indent + 1);
        ast_walk_labeled("start:", expr->as.array_idx_range_node.start,
                         indent + 1);
        ast_walk_labeled("end:", expr->as.array_idx_range_node.end, indent + 1);
        break;
    case EXPR_EWHILE:
        printf(ANSI_RED "EWhile" ANSI_RESET "\n");
        ast_walk_labeled("cond:", expr->as.while_node.cond, indent + 1);
        ast_walk_labeled("body:", expr->as.while_node.body, indent + 1);
        break;
    case EXPR_EFOR:
        printf(ANSI_RED "EFor" ANSI_RESET "\n");
        if (expr->as.for_node.init)
            ast_walk_labeled("init:", expr->as.for_node.init, indent + 1);
        if (expr->as.for_node.cond)
            ast_walk_labeled("cond:", expr->as.for_node.cond, indent + 1);
        if (expr->as.for_node.step)
            ast_walk_labeled("step:", expr->as.for_node.step, indent + 1);
        ast_walk_labeled("body:", expr->as.for_node.body, indent + 1);
        break;
    case EXPR_EFOREACH:
        printf(ANSI_RED "EForEach" ANSI_RESET "  " ANSI_DIM
                         "var=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
               expr->as.foreach_node.var_name);
        ast_walk_labeled("iterable:", expr->as.foreach_node.iterable,
                         indent + 1);
        ast_walk_labeled("body:", expr->as.foreach_node.body, indent + 1);
        break;
    case EXPR_EFORRANGE:
        printf(ANSI_RED "EForRange" ANSI_RESET "  " ANSI_DIM
                         "var=" ANSI_RESET ANSI_BOLD "%s" ANSI_RESET "\n",
               expr->as.forrange_node.var_name);
        ast_walk_labeled("start:", expr->as.forrange_node.start, indent + 1);
        ast_walk_labeled("end:", expr->as.forrange_node.end, indent + 1);
        ast_walk_labeled("body:", expr->as.forrange_node.body, indent + 1);
        break;
    case EXPR_EARRAY_ASSIGN:
        printf(ANSI_BLUE "EArrayAssign" ANSI_RESET "\n");
        ast_walk_labeled("array:", expr->as.array_assign_node.array, indent + 1);
        ast_walk_labeled("idx:", expr->as.array_assign_node.idx, indent + 1);
        ast_walk_labeled("value:", expr->as.array_assign_node.value, indent + 1);
        break;
    case EXPR_ENULL:
        printf(ANSI_DIM "ENull" ANSI_RESET "\n");
        break;
    }
}

static void code_indent(FILE *out, int indent) {
    for (int i = 0; i < indent; i++) { fprintf(out, "    "); }
}

void ast_print_code(FILE *out, Expr *expr, int indent);

static void ast_print_block(FILE *out, Expr *expr, int indent) {
    fprintf(out, ANSI_DIM "{\n" ANSI_RESET);

    for (size_t i = 0; i < expr->as.block_node.count; i++) {
        code_indent(out, indent + 1);
        ast_print_code(out, expr->as.block_node.exprs[i], indent + 1);
        fprintf(out, ";\n");
    }

    code_indent(out, indent);
    fprintf(out, ANSI_DIM "}" ANSI_RESET);
}

void ast_print_code(FILE *out, Expr *expr, int indent) {
    if (!expr) {
        fprintf(out, ANSI_RED "null" ANSI_RESET);
        return;
    }

    switch (expr->kind) {
    case EXPR_ELONG:
        fprintf(out, ANSI_CYAN "%ld" ANSI_RESET, expr->as.elong);
        break;

    case EXPR_EVAR:
        fprintf(out, ANSI_GREEN "%s" ANSI_RESET, expr->as.evar);
        break;

    case EXPR_EFLOAT:
        fprintf(out, ANSI_CYAN "%f" ANSI_RESET, expr->as.efloat);
        break;

    case EXPR_EBOOL:
        fprintf(out, ANSI_YELLOW "%s" ANSI_RESET,
                expr->as.ebool ? "true" : "false");
        break;

    case EXPR_EUNARY:
        fprintf(out, "(" ANSI_MAGENTA "%s" ANSI_RESET " ",
                operator_to_str(expr->as.unary_node.op));
        ast_print_code(out, expr->as.unary_node.operand, indent);
        fprintf(out, ")");
        break;

    case EXPR_ERETURN:
        fprintf(out, ANSI_MAGENTA "return" ANSI_RESET);
        if (expr->as.return_value) {
            fprintf(out, " ");
            ast_print_code(out, expr->as.return_value, indent);
        }
        break;

    case EXPR_EOP:
        fprintf(out, "(");
        ast_print_code(out, expr->as.op_node.left, indent);
        fprintf(out, " " ANSI_MAGENTA "%s" ANSI_RESET " ",
                operator_to_str(expr->as.op_node.op));
        ast_print_code(out, expr->as.op_node.right, indent);
        fprintf(out, ")");
        break;

    case EXPR_EASSIGNMENT:
        fprintf(out,
                ANSI_GREEN "%s" ANSI_RESET " " ANSI_MAGENTA "=" ANSI_RESET " ",
                expr->as.assignment_node.var_name);
        ast_print_code(out, expr->as.assignment_node.value, indent);
        break;

    case EXPR_EDECLARATION:
        fprintf(out,
                ANSI_BLUE "%s" ANSI_RESET " " ANSI_GREEN "%s" ANSI_RESET
                          " " ANSI_MAGENTA "=" ANSI_RESET " ",
                expr->as.declaration_node.kind == DECL_LET ? "let" : "const",
                expr->as.declaration_node.name);

        ast_print_code(out, expr->as.declaration_node.value, indent);
        break;

    case EXPR_EIF:
        fprintf(out, ANSI_BLUE "if" ANSI_RESET " ");
        ast_print_code(out, expr->as.if_node.cond, indent);
        fprintf(out, " ");

        if (expr->as.if_node.then_branch &&
            expr->as.if_node.then_branch->kind == EXPR_EBLOCK) {
            ast_print_block(out, expr->as.if_node.then_branch, indent);
        } else {
            fprintf(out, "\n");
            code_indent(out, indent + 1);
            ast_print_code(out, expr->as.if_node.then_branch, indent + 1);
        }

        if (expr->as.if_node.else_branch) {
            fprintf(out, " " ANSI_BLUE "else" ANSI_RESET " ");

            if (expr->as.if_node.else_branch->kind == EXPR_EBLOCK) {
                ast_print_block(out, expr->as.if_node.else_branch, indent);
            } else {
                ast_print_code(out, expr->as.if_node.else_branch, indent);
            }
        }
        break;

    case EXPR_EBLOCK: ast_print_block(out, expr, indent); break;
    case EXPR_ECALL:
        ast_print_code(out, expr->as.call_node.callee, indent);
        fprintf(out, "(");
        for (size_t i = 0; i < expr->as.call_node.arg_count; i++) {
            if (i > 0) { fprintf(out, ", "); }
            ast_print_code(out, expr->as.call_node.args[i], indent);
        }
        fprintf(out, ")");
        break;
    case EXPR_EFUNC:
        fprintf(out, ANSI_BLUE "def" ANSI_RESET "(");
        for (size_t i = 0; i < expr->as.efunc.param_count; i++) {
            if (i > 0) { fprintf(out, ", "); }
            fprintf(out,
                    ANSI_GREEN "%s" ANSI_RESET ": " ANSI_CYAN "%s" ANSI_RESET,
                    expr->as.efunc.param_names[i],
                    type_t_to_str(expr->as.efunc.param_types[i]));
        }
        fprintf(out, ") -> " ANSI_CYAN "%s" ANSI_RESET " ",
                type_t_to_str(expr->as.efunc.return_type));
        ast_print_code(out, expr->as.efunc.body, indent);
        break;
    case EXPR_ESTR: {
        char *escaped = escape_str(expr->as.estr.data);
        fprintf(out, ANSI_CYAN "\"%s\"" ANSI_RESET, escaped);
        free(escaped);
        break;
    }
    case EXPR_EARRAY:
        fprintf(out, ANSI_CYAN "[" ANSI_RESET);
        for (size_t i = 0; i < expr->as.array_node.count; i++) {
            if (i > 0) { fprintf(out, ", "); }
            ast_print_code(out, expr->as.array_node.elements[i], indent);
        }
        fprintf(out, ANSI_CYAN "]" ANSI_RESET);
        break;
    case EXPR_EMAP:
        fprintf(out, ANSI_CYAN "{" ANSI_RESET);
        for (size_t i = 0; i < expr->as.map_node.count; i++) {
            if (i > 0) { fprintf(out, ", "); }
            if (!expr->as.map_node.entries[i].key) {
                fprintf(out, ANSI_MAGENTA "..." ANSI_RESET);
                ast_print_code(out, expr->as.map_node.entries[i].value, indent);
                continue;
            }
            fprintf(out,
                    ANSI_GREEN "%s" ANSI_RESET ANSI_MAGENTA ":" ANSI_RESET " ",
                    expr->as.map_node.entries[i].key);
            ast_print_code(out, expr->as.map_node.entries[i].value, indent);
        }
        fprintf(out, ANSI_CYAN "}" ANSI_RESET);
        break;
    case EXPR_EARRAY_IDX:
        ast_print_code(out, expr->as.array_idx_node.array, indent);
        fprintf(out, "[");
        ast_print_code(out, expr->as.array_idx_node.idx, indent);
        fprintf(out, "]");
        break;
    case EXPR_EARRAY_IDX_RANGE:
        ast_print_code(out, expr->as.array_idx_range_node.array, indent);
        fprintf(out, "[");
        ast_print_code(out, expr->as.array_idx_range_node.start, indent);
        fprintf(out, ":");
        ast_print_code(out, expr->as.array_idx_range_node.end, indent);
        fprintf(out, "]");
        break;
    }
}