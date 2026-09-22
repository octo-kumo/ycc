#ifndef C_PARSER_H
#define C_PARSER_H
#include "ast.h"
#include <stdint.h>

typedef struct {
    int is_some;
    char *remaining;
    void *value;
} parser_result_t;
typedef parser_result_t (*parser_t)(const char *input);

typedef struct {
    int is_some;
    char *remaining;
    Expr *value;
} ast_parser_result_t;
typedef ast_parser_result_t (*ast_parser_t)(const char *input);

struct parser_list_t;
typedef struct parser_list_t {
    parser_t parser;
    struct parser_list_t *next;
} parser_list_t;
struct list_t;
typedef struct list_t {
    void *value;
    struct list_t *next;
} list_t;

void free_list(list_t *list);
parser_result_t parse_long(const char *input);
parser_result_t parse_many(parser_t p, const char *input);
ast_parser_result_t ast__parse_expr(const char *input);
ast_parser_result_t ast_parse_expr_block(const char *input);
ast_parser_result_t ast__parse_inline_expr(const char *input);
ast_parser_result_t ast__parse_inside_binary_op(const char *input);
#endif