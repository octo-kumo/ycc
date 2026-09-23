#ifndef C_AST_H
#define C_AST_H
#include "list.h"
#include "type.h"
#include <stdbool.h>
#include <stdlib.h>

// extern const char *TYPE_STRS[];
extern const char *OPERATORS[];
// const char *OPERATORS[] = {"<=", ">=", "&&", "||", "==", "!=", "+",
//                            "-",  "*",  "/",  "=",  "<",  ">",  NULL};
extern const char *KEYWORDS[];

typedef enum {
    O_GTE,
    O_LTE,
    O_AND,
    O_OR,
    O_EQ,
    O_NEQ,
    O_ADD,
    O_SUB,
    O_MUL,
    O_DIV,
    O_ASSIGN,
    O_LT,
    O_GT,
    O_CONS, // ::
    O_DOT,  // .   // for accessing fields of map or array length
    O_MOD,  // %
    O_NOT,  // !   // logical NOT (unary)
    O_NEG,  // -   // arithmetic negation (unary)
} Operator;

Operator operator_from_str(const char *op);
const char *operator_to_str(Operator op);

typedef enum {
    EXPR_ELONG,
    EXPR_EBOOL,
    EXPR_EFLOAT,
    EXPR_EARRAY,
    EXPR_EARRAY_IDX,
    EXPR_EARRAY_IDX_RANGE,
    EXPR_EMAP,
    EXPR_ESTR,
    EXPR_EFUNC,
    EXPR_EVAR,
    EXPR_EIF,
    EXPR_EOP,
    EXPR_EASSIGNMENT,
    EXPR_EDECLARATION,
    EXPR_ECALL,
    EXPR_EBLOCK,
    EXPR_EWHILE,
    EXPR_EFOR,
    EXPR_EFOREACH,
    EXPR_EFORRANGE,
    EXPR_EARRAY_ASSIGN,
    EXPR_ENULL,
    EXPR_EUNARY,
    EXPR_ERETURN,
} ExprKind;

typedef enum {
    DECL_CONST,
    DECL_LET,
    DECL_FUNC,
} DeclarationKind;

struct Expr;

typedef struct {
    char *data;
    int length;
} EStr;

typedef struct {
    size_t param_count;
    char **param_names;
    type_t **param_types; // for type checking, not used in execution
    type_t *return_type;  // for type checking, not used in execution
    struct Expr *body;
    bool external; // Indicates if this is an external function (built-in) or a
                   // user-defined one
} EFunc;

typedef struct {
    struct Expr *cond;
    struct Expr *then_branch;
    struct Expr *else_branch; // can be NULL
} EIf;

typedef struct {
    Operator op;
    struct Expr *left;
    struct Expr *right;
} EOp;

typedef struct {
    Operator op;
    struct Expr *operand;
} EUnary;

typedef struct {
    char *var_name;
    struct Expr *value;
} EAssignment;

typedef struct {
    size_t count;
    struct Expr **exprs;
} EBlock;

typedef struct {
    DeclarationKind kind;
    char *name;
    struct Expr *value;
} EDeclaration;

typedef struct {
    struct Expr *callee;
    size_t arg_count;
    struct Expr **args;
} ECall;

typedef struct {
    size_t count;
    LIST(struct Expr *) elements;
} EArray;
typedef struct {
    struct Expr *array;

    struct Expr *start;
    struct Expr *end;
} EArrayIdxRange;
typedef struct {
    struct Expr *array;
    struct Expr *idx;
} EArrayIdx;
typedef struct {
    char *key;
    struct Expr *value;
} EMapEntry;
typedef struct {
    size_t count;
    LIST(EMapEntry) entries;
} EMap;

typedef struct {
    struct Expr *cond;
    struct Expr *body;
} EWhile;

typedef struct {
    struct Expr *init; // can be NULL
    struct Expr *cond; // can be NULL (infinite loop)
    struct Expr *step; // can be NULL
    struct Expr *body;
} EFor;

typedef struct {
    char *var_name;
    struct Expr *iterable;
    struct Expr *body;
} EForEach;

typedef struct {
    char *var_name;
    struct Expr *start;
    struct Expr *end;
    struct Expr *body;
} EForRange;

typedef struct {
    struct Expr *array;
    struct Expr *idx;
    struct Expr *value;
} EArrayAssign;

typedef struct Expr {
    ExprKind kind;
    union {
        long elong;
        double efloat;
        char *evar;
        bool ebool;
        EStr estr;
        EFunc efunc;
        EIf if_node;
        EOp op_node;
        EUnary unary_node;
        EAssignment assignment_node;
        EDeclaration declaration_node;
        ECall call_node;
        EBlock block_node;
        EArray array_node;
        EArrayIdx array_idx_node;
        EArrayIdxRange array_idx_range_node;
        EMap map_node;
        EWhile while_node;
        EFor for_node;
        EForEach foreach_node;
        EForRange forrange_node;
        EArrayAssign array_assign_node;
        /* `return expr;` — NULL for a bare `return;` (yields null). */
        struct Expr *return_value;
    } as;
} Expr;

void ast_free(Expr *expr);
Expr *ast_clone(Expr *expr);

#endif