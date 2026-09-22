#ifndef TYPECHECK_H
#define TYPECHECK_H

#include "ast.h"
#include "map.h"
#include "type.h"
#include <stddef.h>

typedef struct typecheck_result_t {
    int is_ok;
    type_t *type;
    char *error_message;
    Expr *error_expr;
} typecheck_result_t;
typedef struct TCVariableTypes {
    struct TCVariableTypes *parent;
    map_t variables; // Map of variable name to type_t*
} TCVarTypeScope;
typecheck_result_t tc_expr(Expr *expr, TCVarTypeScope *scope);

#endif