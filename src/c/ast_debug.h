#ifndef AST_DEBUG_H
#define AST_DEBUG_H
#include "ast.h"
#include <stdio.h>
void print_escaped(const char *s);
char *escape_str(const char *s);
void ast_walk(Expr *expr, int indent);
void ast_print_code(FILE *out, Expr *expr, int indent);
#endif