#include "parser.h"
#include "ast.h"
#include "list.h"
#include "type.h"
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void free_list(list_t *list) {
    while (list) {
        list_t *next = list->next;
        free(list);
        list = next;
    }
}

#define some(v, r)                                                             \
    ((parser_result_t){                                                        \
        .is_some = 1, .remaining = (char *)(r), .value = (void *)(v)})
#define none(r)                                                                \
    ((parser_result_t){.is_some = 0, .remaining = (char *)(r), .value = NULL})
#define asome(v, r)                                                            \
    ((ast_parser_result_t){                                                    \
        .is_some = 1, .remaining = (char *)(r), .value = (Expr *)(v)})
#define anone(r)                                                               \
    ((ast_parser_result_t){                                                    \
        .is_some = 0, .remaining = (char *)(r), .value = NULL})

void *char_to_int(void *c) { return (void *)((uintptr_t)c - (uintptr_t)'0'); }
void *char_to_sign(void *c) {
    return (void *)((uintptr_t)c == (uintptr_t)'-' ? (void *)-1 : (void *)1);
}

int is_digit(char c) { return c >= '0' && c <= '9'; }
int is_alpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
           is_digit(c);
}
int is_number_sign(char c) { return c == '+' || c == '-'; }
int is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

char *skip_spaces(const char *input) {
    while (*input) {
        // Skip whitespace
        if (is_space(*input)) {
            input++;
        }
        // Skip single-line comments: // ... \n
        else if (input[0] == '/' && input[1] == '/') {
            input += 2;
            while (*input && *input != '\n') input++;
        }
        // Skip multi-line comments: /* ... */
        else if (input[0] == '/' && input[1] == '*') {
            input += 2;
            while (*input && !(input[0] == '*' && input[1] == '/')) input++;
            if (*input) input += 2; // consume closing '*/'
        } else {
            break;
        }
    }
    return (char *)input;
}

parser_result_t parse_satisfy(const char *input, int (*predicate)(char)) {
    if (!input || input[0] == '\0') { return none(input); }
    if (predicate(input[0])) { return some((uintptr_t)(input[0]), input + 1); }
    return none(input);
}

parser_result_t parse_map(parser_result_t res, void *(*f)(void *)) {
    if (res.is_some) { return some(f(res.value), res.remaining); }
    return none(res.remaining);
}
#define MAKE_TAKE_PARSER(name, pred)                                           \
    parser_result_t parse_take_##name(const char *input) {                     \
        return parse_satisfy(input, pred);                                     \
    }

#define MAKE_MAP_PARSER(name, pred, mapper)                                    \
    parser_result_t parse_##name(const char *input) {                          \
        return parse_map(parse_satisfy(input, pred),                           \
                         (void *(*)(void *))mapper);                           \
    }

MAKE_TAKE_PARSER(space, is_space);
MAKE_MAP_PARSER(digit, is_digit, char_to_int);
MAKE_MAP_PARSER(number_sign, is_number_sign, char_to_sign);
MAKE_TAKE_PARSER(alpha, is_alpha);

long digit_list_to_long(list_t *digits) {
    /* Unsigned accumulation: a literal wider than long wraps (two's
     * complement) instead of being signed-overflow UB. The observable
     * result is unchanged; only the undefined behaviour is gone. */
    unsigned long number = 0;
    while (digits) {
        number = number * 10UL + (unsigned long)(uintptr_t)digits->value;
        digits = digits->next;
    }
    return (long)number;
}

char *char_list_to_str(list_t *chars) {
    size_t len = 0;
    list_t *current = chars;
    while (current) {
        len++;
        current = current->next;
    }
    char *str = (char *)malloc(len + 1);
    str[len] = '\0';
    current = chars;
    for (size_t i = 0; i < len; i++) {
        str[i] = (char)(uintptr_t)current->value;
        current = current->next;
    }
    return str;
}

parser_result_t parse_alt(parser_result_t (*p1)(const char *),
                          parser_result_t (*p2)(const char *),
                          const char *input) {
    parser_result_t res1 = p1(input);
    if (res1.is_some) { return res1; }
    return p2(input);
}

parser_result_t parse_seq(parser_list_t *parsers, const char *input) {
    if (!parsers) return none(input);
    parser_result_t res = parsers->parser(input);
    if (!res.is_some) return none(input);
    parser_result_t w = parse_seq(parsers->next, res.remaining);
    if (!w.is_some) return none(input);
    // Combine res.value and w.value into a list
    list_t *combined = (list_t *)malloc(sizeof(list_t));
    combined->value = res.value;
    combined->next = (list_t *)w.value;
    return some(combined, w.remaining);
}

parser_result_t of_value(void *v, const char *input) { return some(v, input); }

parser_result_t of_null(const char *input) { return some(NULL, input); }

parser_result_t parse_bind(parser_t p, void *(*f)(void *), const char *input) {
    parser_result_t res = p(input);
    if (res.is_some) { return some(f(res.value), res.remaining); }
    return none(input);
}

parser_result_t parse_some(parser_t p, const char *input) {
    parser_result_t res = p(input);
    if (!res.is_some) { return none(input); }
    parser_result_t w = parse_many(p, res.remaining);
    list_t *combined = (list_t *)malloc(sizeof(list_t));
    combined->value = res.value;
    combined->next = (list_t *)w.value;
    return some(combined, w.remaining);
}

parser_result_t parse_many(parser_t p, const char *input) {
    parser_result_t res = parse_some(p, input);
    if (res.is_some) { return res; }
    return of_null(input);
}

parser_result_t parse_long(const char *input) {
    const char *original_input = input;
    input = skip_spaces(input);
    parser_result_t sign = parse_number_sign(input);
    int sign_value = sign.is_some ? (int)(uintptr_t)sign.value : 1;
    input = sign.remaining;

    parser_result_t res = parse_some(parse_digit, input);
    if (!res.is_some) { return none(original_input); }
    long number = sign_value * digit_list_to_long((list_t *)res.value);
    free_list((list_t *)res.value);
    return some((void *)(uintptr_t)number, res.remaining);
}

parser_result_t parse_keyword(const char *input, const char *KEYWORDS[]) {
    const char *original_input = input;
    input = skip_spaces(input);
    for (size_t i = 0; KEYWORDS[i]; i++) {
        const char *kw = KEYWORDS[i];
        size_t len = strlen(kw);
        if (strncmp(input, kw, len) == 0 && !isalpha(input[len])) {
            return some((void *)kw, input + len);
        }
    }
    return none(original_input);
}
parser_result_t parse_symbol(const char *input, char sym) {
    input = skip_spaces(input);
    if (input && *input == sym) {
        return some((void *)(uintptr_t)sym, input + 1);
    }
    return none(input);
}

parser_result_t parse_operator(const char *input, const char *OPERATORS[]) {
    const char *original_input = input;
    input = skip_spaces(input);
    for (size_t i = 0; OPERATORS[i]; i++) {
        const char *op = OPERATORS[i];
        size_t len = strlen(op);
        if (strncmp(input, op, len) == 0) {
            return some(operator_from_str(op), input + len);
        }
    }
    return none(original_input);
}

parser_result_t parse_identifier(const char *input) {
    const char *original_input = input;
    input = skip_spaces(input);
    if (!input || input[0] == '\0' || !isalpha(input[0])) {
        return none(original_input);
    }
    parser_result_t res = parse_some(parse_take_alpha, input);
    if (!res.is_some) { return none(original_input); }
    char *identifier = char_list_to_str((list_t *)res.value);

    // check if identifier is a keyword
    for (size_t i = 0; KEYWORDS[i]; i++) {
        if (strcmp(identifier, KEYWORDS[i]) == 0) {
            free(identifier);
            free_list((list_t *)res.value);
            return none(original_input);
        }
    }

    // check if identifier starts with number
    if (is_digit(identifier[0])) {
        free(identifier);
        free_list((list_t *)res.value);
        return none(original_input);
    }

    free_list((list_t *)res.value);
    return some(identifier, res.remaining);
}

parser_result_t parse_type(const char *input, bool allow_complex_types);
parser_result_t __parse_type_group(const char *input) {
    // (type, type) or (type) or type or ()
    // ((type, type) -> type) is also valid
    const char *original_input = input;

    // try to parse (type, type, ...)
    parser_result_t left_paren = parse_symbol(input, '(');
    if (!left_paren.is_some) {
        // try to parse type directly, if success its just a single type,
        // because (...,...) composite types is not a simple type.
        parser_result_t ltype = parse_type(input, false);
        if (ltype.is_some) {
            LIST(type_t *) types = NULL;
            list_init(type_t *, types);
            list_push(type_t *, types, ((type_t *)ltype.value));
            return some(types, ltype.remaining);
        } else {
            return none(original_input);
        }
    }
    input = left_paren.remaining;
    LIST(type_t *) types = NULL;
    list_init(type_t *, types);
    while (1) {
        parser_result_t type_res = parse_type(input, true);
        if (!type_res.is_some) break;
        list_push(type_t *, types, ((type_t *)type_res.value));
        input = type_res.remaining;
        parser_result_t comma_res = parse_symbol(input, ',');
        if (comma_res.is_some) {
            input = comma_res.remaining;
        } else {
            break;
        }
    }
    parser_result_t right_paren = parse_symbol(input, ')');
    if (!right_paren.is_some) {
        list_free(types);
        return none(original_input);
    }
    return some(types, right_paren.remaining);
}

parser_result_t __parse_function_type(const char *input) {
    // (type, type, ...) -> type
    // type->type is also valid
    // ()->()
    const char *original_input = input;
    parser_result_t params_res = __parse_type_group(input);
    if (!params_res.is_some) return none(original_input);
    LIST(type_t *) param_types = (LIST(type_t *))params_res.value;
    input = params_res.remaining;
    parser_result_t arrow_res =
        parse_operator(input, (const char *[]){"->", NULL});
    if (!arrow_res.is_some) {
        list_free(param_types);
        return none(original_input);
    }
    input = arrow_res.remaining;
    parser_result_t return_type_res = parse_type(input, true);
    if (!return_type_res.is_some) {
        list_free(param_types);
        return none(original_input);
    }
    type_t *return_type = (type_t *)return_type_res.value;
    type_t *func_type = tc_make_t(VAL_FUNC);
    func_type->as.func.param_count = list_count(param_types);
    func_type->as.func.param_types = param_types;
    func_type->as.func.return_type = return_type;
    return some(func_type, return_type_res.remaining);
}
parser_result_t __parse_type(const char *input, bool allow_complex_types) {
    const char *original_input = input;
    /*
    the type can be the following
    - a built-in type: long, float, bool, str
    - an array type: [type]
    - a map type: {key: type, key: type, ...}
    - a function type: (type, type, ...) -> type
    */
    // because type->type starts with a perfectly valid type, we need to parse
    // functions first
    if (allow_complex_types) {
        parser_result_t func_res = __parse_function_type(input);
        if (func_res.is_some) return func_res;
    }
    input = original_input;
    const char *built_in_types[] = {"long", "float", "bool", "str", "byte", NULL};
    parser_result_t kw_res = parse_keyword(input, built_in_types);
    if (kw_res.is_some) {
        if (strcmp((char *)kw_res.value, "long") == 0) {
            return some(TYPE_LONG, kw_res.remaining);
        } else if (strcmp((char *)kw_res.value, "byte") == 0) {
            /* The VM has no 8-bit storage class: a byte is a long in
             * 0..255. Only the native backend packs [byte] arrays. */
            return some(TYPE_LONG, kw_res.remaining);
        } else if (strcmp((char *)kw_res.value, "float") == 0) {
            return some(TYPE_FLOAT, kw_res.remaining);
        } else if (strcmp((char *)kw_res.value, "bool") == 0) {
            return some(TYPE_BOOL, kw_res.remaining);
        } else if (strcmp((char *)kw_res.value, "str") == 0) {
            return some(TYPE_STR, kw_res.remaining);
        }
    }
    // assume built-in type parse failed, now try parsing arrays
    parser_result_t arr_start = parse_symbol(input, '[');
    if (arr_start.is_some) {
        parser_result_t elem_type_res = parse_type(arr_start.remaining, true);
        if (!elem_type_res.is_some) return none(original_input);
        parser_result_t arr_end = parse_symbol(elem_type_res.remaining, ']');
        if (!arr_end.is_some) return none(original_input);
        type_t *elem_type = (type_t *)elem_type_res.value;
        type_t *arr_type = tc_make_t(VAL_ARR);
        arr_type->as.array.element_type = elem_type;
        return some(arr_type, arr_end.remaining);
    }
    input = original_input;
    // assume array parse failed, now try parsing maps
    parser_result_t map_start = parse_symbol(input, '{');
    if (map_start.is_some) {
        // {key: type, key: type, ...}
        type_map_entry_t *entries = NULL;
        size_t count = 0;
        input = map_start.remaining;
        while (1) {
            parser_result_t key_res = parse_identifier(input);
            if (!key_res.is_some) break; // no more entries
            char *key = (char *)key_res.value;
            parser_result_t colon_res = parse_symbol(key_res.remaining, ':');
            if (!colon_res.is_some) {
                // '{key}' without ': type' is not valid, we treat it as parse
                // failure
                free(key);
                free(entries);
                return none(original_input);
            }
            parser_result_t type_res = parse_type(colon_res.remaining, true);
            if (!type_res.is_some) {
                // '{key:}' without type is not valid, we treat it as parse
                // failure
                free(key);
                free(entries);
                return none(original_input);
            }
            type_t *value_type = (type_t *)type_res.value;
            entries = (type_map_entry_t *)realloc(
                entries, sizeof(type_map_entry_t) * (count + 1));
            strncpy(entries[count].key, key, 31);
            entries[count].key[31] = '\0';
            entries[count].value = value_type;
            count++;
            free(key);
            parser_result_t comma_res = parse_symbol(type_res.remaining, ',');
            if (comma_res.is_some) {
                input = comma_res.remaining;
            } else {
                input = type_res.remaining;
                break;
            }
        }
        parser_result_t map_end = parse_symbol(input, '}');
        if (!map_end.is_some) {
            free(entries);
            return none(original_input);
        }
        type_t *map_type = tc_make_t(VAL_MAP);
        map_type->as.map.count = count;
        map_type->as.map.entries = entries;
        return some(map_type, map_end.remaining);
    }
    return none(original_input);
}
parser_result_t parse_type(const char *input, bool allow_complex_types) {
    // try to parse directly first, if fail, then try to parse (type)
    const char *original_input = input;
    input = skip_spaces(input);
    parser_result_t res = __parse_type(input, allow_complex_types);
    if (res.is_some) { return res; }

    // try to parse (type)
    parser_result_t left_paren = parse_symbol(input, '(');
    if (!left_paren.is_some) return none(original_input);
    parser_result_t type_res = __parse_type(left_paren.remaining, true);
    if (!type_res.is_some) return none(original_input);
    parser_result_t right_paren = parse_symbol(type_res.remaining, ')');
    if (!right_paren.is_some) return none(original_input);
    type_res.remaining = right_paren.remaining;
    return type_res;
}

/** ######################################################
 */
#define SKIP_SPACES                                                            \
    { input = skip_spaces(input); }
#define EXPECT_KEYWORD(kw)                                                     \
    {                                                                          \
        SKIP_SPACES;                                                           \
        parser_result_t kw##_res =                                             \
            parse_keyword(input, (const char *[]){#kw, NULL});                 \
        if (!kw##_res.is_some || strcmp((char *)kw##_res.value, #kw) != 0) {   \
            return anone(original_input);                                      \
        }                                                                      \
        input = kw##_res.remaining;                                            \
        SKIP_SPACES;                                                           \
    }
#define EXPECT_SYMBOL(sym, fail)                                               \
    {                                                                          \
        SKIP_SPACES;                                                           \
        parser_result_t re = parse_symbol(input, sym);                         \
        if (!re.is_some) {                                                     \
            fail;                                                              \
            return anone(original_input);                                      \
        }                                                                      \
        input = re.remaining;                                                  \
    }

#define MAYBE_KEYWORD(kw, fail)                                                \
    {                                                                          \
        SKIP_SPACES;                                                           \
        parser_result_t kw##_res =                                             \
            parse_keyword(input, (const char *[]){#kw, NULL});                 \
        if (!kw##_res.is_some || strcmp((char *)kw##_res.value, #kw) != 0) {   \
            fail;                                                              \
        }                                                                      \
        input = kw##_res.remaining;                                            \
        SKIP_SPACES;                                                           \
    }
#define MAYBE_SYMBOL(sym, fail)                                                \
    {                                                                          \
        parser_result_t re = parse_symbol(input, sym);                         \
        if (!re.is_some) { fail; }                                             \
        input = re.remaining;                                                  \
        SKIP_SPACES;                                                           \
    }
Expr *ast_of_long(long v) {
    Expr *expr = (Expr *)malloc(sizeof(Expr));
    expr->kind = EXPR_ELONG;
    expr->as.elong = v;
    return expr;
}
ast_parser_result_t ast_parse_var_or_paren_expr(const char *input);
/* Digit value for a radix literal, or -1 if `c` is not a digit in `base`.
 * Underscores are handled by the caller as separators. */
static int radix_digit(char c, int base) {
    int v;
    if (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    else return -1;
    return v < base ? v : -1;
}

/* 0x.. / 0X.. (hex) and 0b.. / 0B.. (binary) integer literals. Returns
 * anone() when the input is not a radix literal, so the caller falls back
 * to the decimal/float path. Digits accumulate in unsigned (wrapping is
 * defined; signed overflow would not be). */
static ast_parser_result_t ast_parse_radix_number(const char *input) {
    const char *p = skip_spaces(input);
    int negative = 0;
    if (*p == '+' || *p == '-') {
        negative = (*p == '-');
        p++;
    }
    if (p[0] != '0') return anone(input);
    int base;
    if (p[1] == 'x' || p[1] == 'X') base = 16;
    else if (p[1] == 'b' || p[1] == 'B') base = 2;
    else return anone(input);

    const char *d = p + 2;
    if (radix_digit(*d, base) < 0) return anone(input); /* "0x" with no digits */
    unsigned long value = 0;
    while (*d == '_' || radix_digit(*d, base) >= 0) {
        if (*d != '_') value = value * (unsigned long)base + (unsigned long)radix_digit(*d, base);
        d++;
    }
    Expr *expr = (Expr *)malloc(sizeof(Expr));
    expr->kind = EXPR_ELONG;
    expr->as.elong = negative ? (long)(0UL - value) : (long)value;
    return asome(expr, (char *)d);
}

/* Scientific notation suffix: e/E, optional sign, one or more digits.
 * Applied to an already-parsed number, which becomes a float. */
static ast_parser_result_t apply_exponent(Expr *expr, char *rest, double mantissa) {
    if (rest[0] != 'e' && rest[0] != 'E') return asome(expr, rest);
    const char *e = rest + 1;
    int esign = 1;
    if (*e == '+' || *e == '-') {
        if (*e == '-') esign = -1;
        e++;
    }
    if (*e < '0' || *e > '9') return asome(expr, rest); /* not an exponent */
    long exp = 0;
    while (*e >= '0' && *e <= '9') {
        exp = exp * 10 + (*e - '0');
        if (exp > 10000) exp = 10000; /* clamp: the result saturates anyway */
        e++;
    }
    double scale = 1.0;
    for (long i = 0; i < exp; i++) scale *= 10.0;
    expr->kind = EXPR_EFLOAT;
    expr->as.efloat = esign > 0 ? mantissa * scale : mantissa / scale;
    return asome(expr, (char *)e);
}

ast_parser_result_t ast_parse_number(const char *input) {
    ast_parser_result_t radix = ast_parse_radix_number(input);
    if (radix.is_some) return radix;
    parser_result_t res = parse_long(input);
    if (!res.is_some) { return anone(input); }
    long value = (long)(uintptr_t)res.value;
    int negative = value < 0 || (value == 0 && input[0] == '-');
    Expr *expr = (Expr *)malloc(sizeof(Expr));
    expr->kind = EXPR_ELONG;
    expr->as.elong = value;
    if (res.remaining[0] != '.') {
        // Integer, unless a scientific-notation suffix follows (1e10).
        return apply_exponent(expr, res.remaining, (double)value);
    }
    // Don't treat ".." as a float decimal point (range operator)
    if (res.remaining[1] == '.') {
        return asome(expr, res.remaining);
    }
    res.remaining++;
    // It's a float!
    expr->kind = EXPR_EFLOAT;
    res = parse_many(parse_digit, res.remaining);
    if (!res.is_some) {
        // no more digits, so its like "123." which is valid and should be
        // treated as 123.0
        expr->as.efloat = (double)value;
        return apply_exponent(expr, res.remaining, (double)value);
    }
    double fraction = 0.0;
    double divisor = 10.0;
    list_t *digits = (list_t *)res.value;
    while (digits) {
        fraction += (uintptr_t)digits->value / divisor;
        divisor *= 10.0;
        digits = digits->next;
    }
    free_list((list_t *)res.value);
    // Apply sign to the combined value, not just the integer part
    double abs_val = (double)(negative ? -value : value) + fraction;
    expr->as.efloat = negative ? -abs_val : abs_val;
    return apply_exponent(expr, res.remaining, expr->as.efloat);
}

ast_parser_result_t ast_parse_variable(const char *input) {
    parser_result_t res = parse_identifier(input);
    if (!res.is_some) { return anone(input); }
    char *name = (char *)res.value;
    Expr *expr = (Expr *)malloc(sizeof(Expr));
    expr->kind = EXPR_EVAR;
    expr->as.evar = name;
    return asome(expr, res.remaining);
}

ast_parser_result_t ast_parse_true_false(const char *input) {
    const char *original_input = input;
    parser_result_t true_res =
        parse_keyword(input, (const char *[]){"true", NULL});
    if (true_res.is_some) {
        Expr *expr = (Expr *)malloc(sizeof(Expr));
        expr->kind = EXPR_EBOOL;
        expr->as.ebool = true;
        return asome(expr, true_res.remaining);
    }
    parser_result_t false_res =
        parse_keyword(input, (const char *[]){"false", NULL});
    if (false_res.is_some) {
        Expr *expr = (Expr *)malloc(sizeof(Expr));
        expr->kind = EXPR_EBOOL;
        expr->as.ebool = false;
        return asome(expr, false_res.remaining);
    }
    parser_result_t null_res =
        parse_keyword(input, (const char *[]){"null", NULL});
    if (null_res.is_some) {
        Expr *expr = (Expr *)malloc(sizeof(Expr));
        expr->kind = EXPR_ENULL;
        return asome(expr, null_res.remaining);
    }
    return anone(original_input);
}

ast_parser_result_t ast_parse_string(const char *input) {
    const char *original_input = input;
    EXPECT_SYMBOL('"', );
    char *chars = NULL;
    size_t len = 0;

#define P_STR_APPEND_CHAR(c)                                                   \
    {                                                                          \
        len++;                                                                 \
        chars = (char *)realloc(chars, len + 1);                               \
        chars[len - 1] = (char)(c);                                            \
        chars[len] = '\0';                                                     \
    }

    for (int i = 0; input[i]; i++) {
        if (input[i] == '\\') {
            /* A backslash as the final byte would make the `i++` below step
             * PAST the NUL, so the loop condition then reads out of bounds
             * (ASan: heap-buffer-overflow). An unterminated escape can only
             * be an unterminated string, so stop here. */
            char next = input[i + 1];
            if (next == '\0') break;
            // Handle escape sequences, supportes \n \t \r \" \xhh
            if (next == 'n') {
                P_STR_APPEND_CHAR('\n');
            } else if (next == 't') {
                P_STR_APPEND_CHAR('\t');
            } else if (next == 'r') {
                P_STR_APPEND_CHAR('\r');
            } else if (next == '"') {
                P_STR_APPEND_CHAR('"');
            } else if (next == 'x' && isxdigit((unsigned char)input[i + 2]) &&
                       isxdigit((unsigned char)input[i + 3])) {
                char hex[3] = {input[i + 2], input[i + 3], '\0'};
                P_STR_APPEND_CHAR((char)strtol(hex, NULL, 16));
                i += 2;
            } else {
                // Invalid escape sequence, treat as literal
                P_STR_APPEND_CHAR(next);
            }
            i++;
        } else {
            if (input[i] == '"') {
                input += i + 1;
                Expr *expr = (Expr *)malloc(sizeof(Expr));
                expr->kind = EXPR_ESTR;
                if (!chars) {
                    chars = (char *)malloc(1);
                    chars[0] = '\0';
                }
                expr->as.estr.data = chars;
                expr->as.estr.length = len;
                return asome(expr, input);
            } else {
                P_STR_APPEND_CHAR(input[i]);
            }
        }
    }
    /* Only report once — multiple parser alternatives may each reach here
     * while backtracking over the same unterminated literal. */
    static int reported_unterminated = 0;
    if (!reported_unterminated) {
        fprintf(stderr, "Unterminated string literal\n");
        reported_unterminated = 1;
    }
    free(chars);
    return anone(original_input);
}
ast_parser_result_t ast_parse_declaration(const char *input) {
    const char *original_input = input;
    const char *KEYWORDS[] = {"let", "const", NULL};
    parser_result_t op = parse_keyword(input, KEYWORDS);
    if (!op.is_some || (strcmp((char *)op.value, "let") != 0 &&
                        strcmp((char *)op.value, "const") != 0)) {
        return anone(original_input);
    }
    char *kind = (char *)op.value;
    input = op.remaining;
    parser_result_t id_res = parse_identifier(input);
    if (!id_res.is_some) { return anone(original_input); }
    char *name = (char *)id_res.value;
    input = id_res.remaining;

    SKIP_SPACES;
    if (input[0] == ':') {
        // type annotation will just be parsed and ignored for now.
        input++;
        parser_result_t type_res = parse_type(input, true);
        if (!type_res.is_some) {
            free(name);
            return anone(original_input);
        }
        input = type_res.remaining;
    }

    EXPECT_SYMBOL('=', { free(name); });
    ast_parser_result_t expr_res = ast__parse_expr(input);
    if (!expr_res.is_some) {
        free(name);
        return anone(original_input);
    }
    input = expr_res.remaining;
    DeclarationKind decl_kind =
        strcmp(kind, "let") == 0 ? DECL_LET : DECL_CONST;
    Expr *result = (Expr *)malloc(sizeof(Expr));
    result->kind = EXPR_EDECLARATION;
    result->as.declaration_node = (EDeclaration){
        .kind = decl_kind,
        .name = name,
        .value = expr_res.value,
    };
    return asome(result, input);
}

ast_parser_result_t ast_parse_paren_expr(const char *input) {
    const char *original_input = input;
    EXPECT_SYMBOL('(', );
    ast_parser_result_t inner = ast__parse_inline_expr(input);
    if (!inner.is_some) { return anone(original_input); }
    input = inner.remaining;
    EXPECT_SYMBOL(')', ast_free(inner.value););
    return asome(inner.value, input);
}

/* Unary logical NOT: !expr. Binds tighter than binary ops; the operand is a
 * full inline expression so `!a && b` parses as `(!a) && b`. */
ast_parser_result_t ast_parse_unary(const char *input) {
    const char *original_input = input;
    SKIP_SPACES;
    if (input[0] != '!' && input[0] != '-') { return anone(original_input); }
    if (input[0] == '!' && input[1] == '=') { return anone(original_input); }
    char op_char = input[0];
    input++; /* consume '!' or '-' */
    ast_parser_result_t operand = ast__parse_inside_binary_op(input);
    if (!operand.is_some) { return anone(original_input); }
    Expr *node = (Expr *)malloc(sizeof(Expr));
    node->kind = EXPR_EUNARY;
    node->as.unary_node.op = (op_char == '!') ? O_NOT : O_NEG;
    node->as.unary_node.operand = operand.value;
    return asome(node, operand.remaining);
}

ast_parser_result_t ast_parse_brace_block(const char *input) {
    const char *original_input = input;

    EXPECT_SYMBOL('{', );

    ast_parser_result_t body = ast_parse_expr_block(input);
    if (!body.is_some) {
        Expr *empty = (Expr *)malloc(sizeof(Expr));
        empty->kind = EXPR_EBLOCK;
        empty->as.block_node.exprs = NULL;
        empty->as.block_node.count = 0;
        body.value = empty;
    }
    input = body.remaining;

    EXPECT_SYMBOL('}', ast_free(body.value););
    return asome(body.value, input);
}

ast_parser_result_t ast_parse_if(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(if);
    ast_parser_result_t ast_cond = ast_parse_paren_expr(input);
    if (!ast_cond.is_some) { return anone(original_input); }
    input = ast_cond.remaining;

    ast_parser_result_t ast_then = ast_parse_brace_block(input);
    if (!ast_then.is_some) {
        ast_free(ast_cond.value);
        return anone(original_input);
    }

    input = ast_then.remaining;

    Expr *if_node = (Expr *)malloc(sizeof(Expr));
    if_node->kind = EXPR_EIF;
    if_node->as.if_node.cond = ast_cond.value;
    if_node->as.if_node.then_branch = ast_then.value;
    if_node->as.if_node.else_branch = NULL;
    MAYBE_KEYWORD(else, { return asome(if_node, input); });

    // Support "else if" chains: try parsing another if first
    ast_parser_result_t ast_else = ast_parse_if(input);
    if (!ast_else.is_some) {
        ast_else = ast_parse_brace_block(input);
    }
    if_node->as.if_node.else_branch = ast_else.value;
    input = ast_else.remaining;
    return asome(if_node, input);
}

/* `return expr;` / `return;` — early exit from the enclosing function.
 * The value (null for a bare return) becomes the function's result. */
ast_parser_result_t ast_parse_return(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(return);

    Expr *node = (Expr *)malloc(sizeof(Expr));
    node->kind = EXPR_ERETURN;
    node->as.return_value = NULL;

    /* A bare `return` is followed by `;` or the end of the block. */
    const char *after = skip_spaces(input);
    if (*after == ';' || *after == '}' || *after == '\0')
        return asome(node, input);

    ast_parser_result_t val = ast__parse_inline_expr(input);
    if (!val.is_some) return asome(node, input); /* bare return */
    node->as.return_value = val.value;
    return asome(node, val.remaining);
}

/* ── Operator precedence ────────────────────────────────────────────────── */

static int op_precedence(Operator op) {
    switch (op) {
    case O_OR:  return 1;
    case O_AND: return 2;
    case O_EQ: case O_NEQ: return 3;
    case O_LT: case O_GT: case O_LTE: case O_GTE: return 4;
    case O_ADD: case O_SUB: return 5;
    case O_MUL: case O_DIV: case O_MOD: return 6;
    case O_CONS: return 7;
    case O_DOT:  return 8;
    default:     return 0;
    }
}

/* Parse an expression with minimum precedence min_prec (precedence climbing).
 * Left-associative ops use min_prec+1 for the RHS; right-assoc (::) uses
 * min_prec so it chains to the right. */
static ast_parser_result_t ast_parse_prec_rhs(const char *input, int min_prec) {
    ast_parser_result_t left = ast__parse_inside_binary_op(input);
    if (!left.is_some) { return anone(input); }

    while (1) {
        parser_result_t op_res = parse_operator(left.remaining, OPERATORS);
        if (!op_res.is_some) { break; }
        Operator op = (Operator)(uintptr_t)op_res.value;
        if (op == O_ASSIGN) { break; }
        int prec = op_precedence(op);
        if (prec < min_prec || prec == 0) { break; }

        int next_min = (op == O_CONS) ? prec : prec + 1;
        ast_parser_result_t right =
            ast_parse_prec_rhs(op_res.remaining, next_min);
        if (!right.is_some) {
            ast_free(left.value);
            return anone(input);
        }
        Expr *node = (Expr *)malloc(sizeof(Expr));
        node->kind = EXPR_EOP;
        node->as.op_node.op = op;
        node->as.op_node.left = left.value;
        node->as.op_node.right = right.value;
        left.value = node;
        left.remaining = right.remaining;
    }
    return left;
}

ast_parser_result_t ast_parse_binary_op(const char *input) {
    const char *original_input = input;

    ast_parser_result_t left = ast__parse_inside_binary_op(input);
    if (!left.is_some) { return anone(original_input); }

    /* Compound assignment: `x += e` desugars to `x = x + e` (same for
     * -=, *=, /=). Handled before the generic operator scan, which would
     * otherwise see a bare `+` followed by `=`. Variable targets only. */
    {
        const char *q = skip_spaces(left.remaining);
        char cop = 0;
        if ((q[0] == '+' || q[0] == '-' || q[0] == '*' || q[0] == '/') &&
            q[1] == '=' && q[2] != '=')
            cop = q[0];
        if (cop && left.value->kind == EXPR_EVAR) {
            ast_parser_result_t rhs = ast__parse_inline_expr(q + 2);
            if (!rhs.is_some) {
                ast_free(left.value);
                return anone(original_input);
            }
            Expr *var_ref = (Expr *)malloc(sizeof(Expr));
            var_ref->kind = EXPR_EVAR;
            var_ref->as.evar = strdup(left.value->as.evar);

            Expr *binop = (Expr *)malloc(sizeof(Expr));
            binop->kind = EXPR_EOP;
            binop->as.op_node.op = cop == '+'   ? O_ADD
                                   : cop == '-' ? O_SUB
                                   : cop == '*' ? O_MUL
                                                : O_DIV;
            binop->as.op_node.left = var_ref;
            binop->as.op_node.right = rhs.value;

            Expr *assign_node = (Expr *)malloc(sizeof(Expr));
            assign_node->kind = EXPR_EASSIGNMENT;
            assign_node->as.assignment_node.var_name = left.value->as.evar;
            assign_node->as.assignment_node.value = binop;
            free(left.value); /* name ownership moved into assign_node */
            return asome(assign_node, rhs.remaining);
        }
    }

    /* Require at least one operator so we don't shadow plain atoms */
    parser_result_t op_check = parse_operator(left.remaining, OPERATORS);
    if (!op_check.is_some) {
        ast_free(left.value);
        return anone(original_input);
    }

    /* Assignment: x = expr or arr[i] = expr */
    Operator first_op = (Operator)(uintptr_t)op_check.value;
    if (first_op == O_ASSIGN) {
        if (left.value->kind == EXPR_EVAR) {
            ast_parser_result_t right =
                ast__parse_inline_expr(op_check.remaining);
            if (!right.is_some) {
                ast_free(left.value);
                return anone(original_input);
            }
            Expr *assign_node = (Expr *)malloc(sizeof(Expr));
            assign_node->kind = EXPR_EASSIGNMENT;
            assign_node->as.assignment_node.var_name = left.value->as.evar;
            assign_node->as.assignment_node.value = right.value;
            free(left.value);
            return asome(assign_node, right.remaining);
        }
        if (left.value->kind == EXPR_EARRAY_IDX) {
            ast_parser_result_t right =
                ast__parse_inline_expr(op_check.remaining);
            if (!right.is_some) {
                ast_free(left.value);
                return anone(original_input);
            }
            Expr *node = (Expr *)malloc(sizeof(Expr));
            node->kind = EXPR_EARRAY_ASSIGN;
            node->as.array_assign_node.array = left.value->as.array_idx_node.array;
            node->as.array_assign_node.idx = left.value->as.array_idx_node.idx;
            node->as.array_assign_node.value = right.value;
            free(left.value); /* free the shell, children moved */
            return asome(node, right.remaining);
        }
        ast_free(left.value);
        return anone(original_input);
    }

    /* Precedence-climbing loop for binary operators */
    while (1) {
        parser_result_t op_res = parse_operator(left.remaining, OPERATORS);
        if (!op_res.is_some) { break; }
        Operator op = (Operator)(uintptr_t)op_res.value;
        if (op == O_ASSIGN) { break; }
        int prec = op_precedence(op);
        if (prec == 0) { break; }

        int next_min = (op == O_CONS) ? prec : prec + 1;
        ast_parser_result_t right =
            ast_parse_prec_rhs(op_res.remaining, next_min);
        if (!right.is_some) {
            ast_free(left.value);
            return anone(original_input);
        }
        Expr *node = (Expr *)malloc(sizeof(Expr));
        node->kind = EXPR_EOP;
        node->as.op_node.op = op;
        node->as.op_node.left = left.value;
        node->as.op_node.right = right.value;
        left.value = node;
        left.remaining = right.remaining;
    }
    return left;
}

ast_parser_result_t ast_parse_array_idx(const char *input) {
    const char *original_input = input;
    ast_parser_result_t ast_arr = ast_parse_var_or_paren_expr(input);
    if (!ast_arr.is_some) { return anone(original_input); }
    input = ast_arr.remaining;

    Expr *current = ast_arr.value;
    int indexed = 0;

    /* Loop to support chained postfix suffixes: x[1][0], x[0][1:3], and
     * field access x.y. Dot is postfix here, NOT a binary operator: as a
     * binary operator its right side was parsed as a full expression, so
     * `x.y[i]` became `x.(y[i])` -- the reason src/y/*.y binds `let t =
     * x.y;` before every indexed field read. Postfix chaining also makes
     * `!x.y` mean `!(x.y)`, since the unary parser takes this operand. */
    while (1) {
        SKIP_SPACES;
        if (input[0] == '.' && input[1] != '.') {
            const char *after_dot = skip_spaces(input + 1);
            parser_result_t name = parse_identifier(after_dot);
            if (!name.is_some) break; /* not a field access */
            char *field = (char *)name.value;
            /* `x.f(...)` stays a method-style call for the call parser and
             * codegen to resolve, so only take plain field reads here. */
            const char *after_name = skip_spaces(name.remaining);
            if (after_name[0] == '(') {
                free(field);
                break;
            }
            Expr *fld = (Expr *)malloc(sizeof(Expr));
            fld->kind = EXPR_EVAR;
            fld->as.evar = field;
            Expr *dot = (Expr *)malloc(sizeof(Expr));
            dot->kind = EXPR_EOP;
            dot->as.op_node.op = O_DOT;
            dot->as.op_node.left = current;
            dot->as.op_node.right = fld;
            current = dot;
            input = name.remaining;
            indexed = 1;
            continue;
        }
        if (input[0] != '[') { break; }
        const char *after_bracket = input + 1;

        ast_parser_result_t ast_idx = ast__parse_expr(after_bracket);
        const char *p = ast_idx.remaining;
        parser_result_t mid_res = parse_symbol(p, ':');
        p = mid_res.remaining;
        ast_parser_result_t ast_end_idx =
            mid_res.is_some ? ast__parse_expr(p) : anone(p);
        p = ast_end_idx.remaining;
        p = skip_spaces(p);
        if (p[0] != ']') {
            if (ast_idx.is_some) { ast_free(ast_idx.value); }
            if (ast_end_idx.is_some) { ast_free(ast_end_idx.value); }
            break; /* not a valid index suffix; stop chaining */
        }
        p++; /* consume ']' */

        if (mid_res.is_some) {
            Expr *slice_node = (Expr *)malloc(sizeof(Expr));
            slice_node->kind = EXPR_EARRAY_IDX_RANGE;
            slice_node->as.array_idx_range_node.array = current;
            slice_node->as.array_idx_range_node.start =
                ast_idx.is_some ? ast_idx.value : ast_of_long(0);
            slice_node->as.array_idx_range_node.end =
                ast_end_idx.is_some ? ast_end_idx.value : ast_of_long(-9223372036854775807);
            current = slice_node;
        } else if (ast_idx.is_some) {
            Expr *idx_node = (Expr *)malloc(sizeof(Expr));
            idx_node->kind = EXPR_EARRAY_IDX;
            idx_node->as.array_idx_node.array = current;
            idx_node->as.array_idx_node.idx = ast_idx.value;
            if (ast_end_idx.is_some) { ast_free(ast_end_idx.value); }
            current = idx_node;
        } else {
            if (ast_end_idx.is_some) { ast_free(ast_end_idx.value); }
            break;
        }
        input = p;
        indexed = 1;
    }

    if (!indexed) {
        ast_free(current);
        return anone(original_input);
    }

    /* Array assignment: only supported for a single-level index target
     * (arr[i] = val). Deeper chains (arr[i][j] = val) are left as a normal
     * indexed-read expression; the '=' is handled by the binary-op parser. */
    if (current->kind == EXPR_EARRAY_IDX) {
        SKIP_SPACES;
        parser_result_t assign_res = parse_symbol(input, '=');
        if (assign_res.is_some && assign_res.remaining[0] != '=') {
            const char *ainput = assign_res.remaining;
            ast_parser_result_t val_res = ast__parse_inline_expr(ainput);
            if (!val_res.is_some) {
                ast_free(current);
                return anone(original_input);
            }
            Expr *arr_expr = current->as.array_idx_node.array;
            Expr *idx_expr = current->as.array_idx_node.idx;
            free(current); /* reuse children, drop the EARRAY_IDX shell */
            Expr *node = (Expr *)malloc(sizeof(Expr));
            node->kind = EXPR_EARRAY_ASSIGN;
            node->as.array_assign_node.array = arr_expr;
            node->as.array_assign_node.idx = idx_expr;
            node->as.array_assign_node.value = val_res.value;
            return asome(node, val_res.remaining);
        }
    }

    /* Field assignment: `s.f = v`. Reuses the array-assign node with a
     * string key, so the engines dispatch on the target's runtime type --
     * which also makes `m["k"] = v` work. Only a single-level target is
     * taken here; deeper chains stay reads. */
    if (current->kind == EXPR_EOP && current->as.op_node.op == O_DOT &&
        current->as.op_node.right &&
        current->as.op_node.right->kind == EXPR_EVAR) {
        SKIP_SPACES;
        parser_result_t assign_res = parse_symbol(input, '=');
        if (assign_res.is_some && assign_res.remaining[0] != '=') {
            const char *ainput = assign_res.remaining;
            ast_parser_result_t val_res = ast__parse_inline_expr(ainput);
            if (!val_res.is_some) {
                ast_free(current);
                return anone(original_input);
            }
            Expr *obj_expr = current->as.op_node.left;
            Expr *key_node = current->as.op_node.right;
            Expr *key_expr = (Expr *)malloc(sizeof(Expr));
            key_expr->kind = EXPR_ESTR;
            key_expr->as.estr.data = strdup(key_node->as.evar);
            key_expr->as.estr.length = (int)strlen(key_node->as.evar);
            ast_free(key_node);
            free(current); /* reuse the object, drop the EOp shell */
            Expr *node = (Expr *)malloc(sizeof(Expr));
            node->kind = EXPR_EARRAY_ASSIGN;
            node->as.array_assign_node.array = obj_expr;
            node->as.array_assign_node.idx = key_expr;
            node->as.array_assign_node.value = val_res.value;
            return asome(node, val_res.remaining);
        }
    }

    return asome(current, input);
}

ast_parser_result_t ast_parse_function(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(def);
    parser_result_t id_res = parse_identifier(input);
    input = id_res.remaining;
    EXPECT_SYMBOL('(', {
        free(id_res.value);
        return anone(original_input);
    });
    LIST(char *) param_names = NULL;
    list_init(char *, param_names);
    LIST(type_t *) param_types = NULL;
    list_init(type_t *, param_types);

    goto _L_CONTINUE;

    // this label is used to free all the allocated memory for parameters and
    // return
_L_FREE_ALL_AND_RETURN_NONE:
    free(id_res.value);
    for (size_t i = 0; i < list_count(param_names); i++) {
        free(param_names[i]);
    }
    list_free(param_names);
    list_free(param_types);
    return anone(original_input);

_L_CONTINUE:

    while (1) {
        // parse parameter name and optional type, the syntax is "name" or "name: type"
        parser_result_t param_res = parse_identifier(input);
        if (!param_res.is_some) { break; }
        input = param_res.remaining;
        
        type_t *param_type = _TYPE_INFERRED;
        parser_result_t colon_res = parse_symbol(input, ':');
        if (colon_res.is_some) {
            input = colon_res.remaining;
            parser_result_t type_res = parse_type(input, true);
            if (!type_res.is_some) {
                free(param_res.value);
                goto _L_FREE_ALL_AND_RETURN_NONE;
            }
            param_type = (type_t *)type_res.value;
            input = type_res.remaining;
        }
        
        list_push(char *, param_names, param_res.value);
        list_push(type_t *, param_types, param_type);
        
        parser_result_t comma_res = parse_symbol(input, ',');
        if (comma_res.is_some) {
            input = comma_res.remaining;
        } else {
            break;
        }
    }
    EXPECT_SYMBOL(')', goto _L_FREE_ALL_AND_RETURN_NONE;);
    type_t *return_type = _TYPE_INFERRED;
    parser_result_t arrow_res =
        parse_operator(input, (const char *[]){"->", NULL});
    if (arrow_res.is_some) {
        input = arrow_res.remaining;
        parser_result_t return_type_res = parse_type(input, false);
        if (!return_type_res.is_some) { goto _L_FREE_ALL_AND_RETURN_NONE; }
        return_type = (type_t *)return_type_res.value;
        input = return_type_res.remaining;
    }

    ast_parser_result_t body_res = ast_parse_brace_block(input);
    if (!body_res.is_some) goto _L_FREE_ALL_AND_RETURN_NONE;
    input = body_res.remaining;
    Expr *func_node = (Expr *)malloc(sizeof(Expr));
    func_node->kind = EXPR_EFUNC;
    func_node->as.efunc = (EFunc){
        .param_count = list_count(param_names),
        .param_names = param_names,
        .param_types = param_types,
        .return_type = return_type,
        .body = body_res.value,
        .external = false,
    };
    if (id_res.is_some) {
        // If function has a name, we treat it as a declaration in the current
        // scope
        Expr *decl_node = (Expr *)malloc(sizeof(Expr));
        decl_node->kind = EXPR_EDECLARATION;
        decl_node->as.declaration_node.kind = DECL_FUNC;
        decl_node->as.declaration_node.name = (char *)id_res.value;
        decl_node->as.declaration_node.value = func_node;
        return asome(decl_node, input);
    } else {
        // Anonymous function, just return the function node
        return asome(func_node, input);
    }
}

ast_parser_result_t ast_parse_var_or_paren_expr(const char *input) {
    // this will work either for just a identifier, or a parenthesized
    // expression.
    ast_parser_result_t var_res = ast_parse_variable(input);
    if (var_res.is_some) { return var_res; }
    return ast_parse_paren_expr(input);
}

/* ── Loop parsers ───────────────────────────────────────────────────────── */

ast_parser_result_t ast_parse_while(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(while);
    ast_parser_result_t ast_cond = ast_parse_paren_expr(input);
    if (!ast_cond.is_some) { return anone(original_input); }
    input = ast_cond.remaining;
    ast_parser_result_t ast_body = ast_parse_brace_block(input);
    if (!ast_body.is_some) {
        ast_free(ast_cond.value);
        return anone(original_input);
    }
    input = ast_body.remaining;
    Expr *node = (Expr *)malloc(sizeof(Expr));
    node->kind = EXPR_EWHILE;
    node->as.while_node.cond = ast_cond.value;
    node->as.while_node.body = ast_body.value;
    return asome(node, input);
}

ast_parser_result_t ast_parse_foreach(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(foreach);
    EXPECT_SYMBOL('(', return anone(original_input););
    parser_result_t var_res = parse_identifier(input);
    if (!var_res.is_some) { return anone(original_input); }
    char *var_name = (char *)var_res.value;
    input = var_res.remaining;
    EXPECT_KEYWORD(in);
    ast_parser_result_t iter_res = ast__parse_expr(input);
    if (!iter_res.is_some) {
        free(var_name);
        return anone(original_input);
    }
    input = iter_res.remaining;
    EXPECT_SYMBOL(')', {
        free(var_name);
        ast_free(iter_res.value);
    });
    ast_parser_result_t body_res = ast_parse_brace_block(input);
    if (!body_res.is_some) {
        free(var_name);
        ast_free(iter_res.value);
        return anone(original_input);
    }
    input = body_res.remaining;
    Expr *node = (Expr *)malloc(sizeof(Expr));
    node->kind = EXPR_EFOREACH;
    node->as.foreach_node.var_name = var_name;
    node->as.foreach_node.iterable = iter_res.value;
    node->as.foreach_node.body = body_res.value;
    return asome(node, input);
}

ast_parser_result_t ast_parse_for(const char *input) {
    const char *original_input = input;
    EXPECT_KEYWORD(for);

    /* Try range form first: for i in start..end { body } */
    {
        const char *save = input;
        parser_result_t var_res = parse_identifier(input);
        if (var_res.is_some) {
            char *var_name = (char *)var_res.value;
            input = var_res.remaining;
            SKIP_SPACES;
            parser_result_t in_res =
                parse_keyword(input, (const char *[]){"in", NULL});
            if (in_res.is_some) {
                input = in_res.remaining;
                ast_parser_result_t start_res = ast__parse_expr(input);
                if (start_res.is_some) {
                    input = start_res.remaining;
                    SKIP_SPACES;
                    /* expect .. */
                    if (input[0] == '.' && input[1] == '.') {
                        input += 2;
                        ast_parser_result_t end_res = ast__parse_expr(input);
                        if (end_res.is_some) {
                            input = end_res.remaining;
                            ast_parser_result_t body_res =
                                ast_parse_brace_block(input);
                            if (body_res.is_some) {
                                input = body_res.remaining;
                                Expr *node = (Expr *)malloc(sizeof(Expr));
                                node->kind = EXPR_EFORRANGE;
                                node->as.forrange_node.var_name = var_name;
                                node->as.forrange_node.start = start_res.value;
                                node->as.forrange_node.end = end_res.value;
                                node->as.forrange_node.body = body_res.value;
                                return asome(node, input);
                            }
                            ast_free(end_res.value);
                        }
                        ast_free(start_res.value);
                        free(var_name);
                        return anone(original_input);
                    }
                    ast_free(start_res.value);
                }
                free(var_name);
                return anone(original_input);
            }
            free(var_name);
            input = save;
        }
    }

    /* C-style for: for (init; cond; step) { body } */
    EXPECT_SYMBOL('(', return anone(original_input););

    /* init (optional) */
    Expr *init = NULL;
    SKIP_SPACES;
    if (input[0] != ';') {
        ast_parser_result_t init_res = ast__parse_expr(input);
        if (init_res.is_some) {
            init = init_res.value;
            input = init_res.remaining;
        }
    }
    EXPECT_SYMBOL(';', { ast_free(init); });

    /* cond (optional) */
    Expr *cond = NULL;
    SKIP_SPACES;
    if (input[0] != ';') {
        ast_parser_result_t cond_res = ast__parse_expr(input);
        if (cond_res.is_some) {
            cond = cond_res.value;
            input = cond_res.remaining;
        }
    }
    EXPECT_SYMBOL(';', {
        ast_free(init);
        ast_free(cond);
    });

    /* step (optional) */
    Expr *step = NULL;
    SKIP_SPACES;
    if (input[0] != ')') {
        ast_parser_result_t step_res = ast__parse_expr(input);
        if (step_res.is_some) {
            step = step_res.value;
            input = step_res.remaining;
        }
    }
    EXPECT_SYMBOL(')', {
        ast_free(init);
        ast_free(cond);
        ast_free(step);
    });

    ast_parser_result_t body_res = ast_parse_brace_block(input);
    if (!body_res.is_some) {
        ast_free(init);
        ast_free(cond);
        ast_free(step);
        return anone(original_input);
    }
    input = body_res.remaining;

    Expr *node = (Expr *)malloc(sizeof(Expr));
    node->kind = EXPR_EFOR;
    node->as.for_node.init = init;
    node->as.for_node.cond = cond;
    node->as.for_node.step = step;
    node->as.for_node.body = body_res.value;
    return asome(node, input);
}

ast_parser_result_t ast_parse_function_call(const char *input) {
    const char *original_input = input;
    ast_parser_result_t ast_callee = ast_parse_var_or_paren_expr(input);
    if (!ast_callee.is_some) { return anone(original_input); }
    input = ast_callee.remaining;

    /* Allow a dot-access chain as the callee so that `m.f(args)` parses as
     * a call of the field `f` on `m`, rather than `m . (f(args))`. */
    while (1) {
        const char *save = input;
        SKIP_SPACES;
        if (input[0] != '.') { input = save; break; }
        const char *after_dot = input + 1;
        parser_result_t field = parse_identifier(after_dot);
        if (!field.is_some) { input = save; break; }
        Expr *field_node = (Expr *)malloc(sizeof(Expr));
        field_node->kind = EXPR_EVAR;
        field_node->as.evar = (char *)field.value;
        Expr *dot_node = (Expr *)malloc(sizeof(Expr));
        dot_node->kind = EXPR_EOP;
        dot_node->as.op_node.op = O_DOT;
        dot_node->as.op_node.left = ast_callee.value;
        dot_node->as.op_node.right = field_node;
        ast_callee.value = dot_node;
        input = field.remaining;
    }

    EXPECT_SYMBOL('(', {
        ast_free(ast_callee.value);
        return anone(original_input);
    });
    Expr **args = NULL;
    size_t arg_count = 0;
    while (1) {
        ast_parser_result_t arg_res = ast__parse_expr(input);
        if (!arg_res.is_some) { break; }
        input = arg_res.remaining;
        arg_count++;
        args = (Expr **)realloc(args, sizeof(Expr *) * arg_count);
        args[arg_count - 1] = (Expr *)arg_res.value;
        EXPECT_SYMBOL(',', { break; });
    }
    EXPECT_SYMBOL(')', {
        for (size_t i = 0; i < arg_count; i++) { ast_free(args[i]); }
        free(args);
        ast_free(ast_callee.value);
        return anone(original_input);
    });
    Expr *call_node = (Expr *)malloc(sizeof(Expr));
    call_node->kind = EXPR_ECALL;
    call_node->as.call_node.callee = ast_callee.value;
    call_node->as.call_node.arg_count = arg_count;
    call_node->as.call_node.args = args;
    return asome(call_node, input);
}

ast_parser_result_t ast_parse_map(const char *input) {
    // works like this
    // {key: value, key: value, ...}
    const char *original_input = input;
    EXPECT_SYMBOL('{', );
    LIST(EMapEntry) entries = NULL;
    list_init(EMapEntry, entries);
    goto _L_TRY_PARSE;

_L_PARSE_MAP_FAILED:
    for (size_t i = 0; i < list_count(entries); i++) {
        free(entries[i].key);
        ast_free(entries[i].value);
    }
    list_free(entries);
    return anone(original_input);

_L_TRY_PARSE:
    while (1) {
        /* Spread: `{a: 1, ...b}` / `{...c, ...d}`. Stored as an entry with
         * a NULL key; the engines splice the spread map's entries in at
         * this position, so later keys win. */
        {
            const char *sp = skip_spaces(input);
            if (sp[0] == '.' && sp[1] == '.' && sp[2] == '.') {
                ast_parser_result_t src_res = ast__parse_expr(sp + 3);
                if (!src_res.is_some) goto _L_PARSE_MAP_FAILED;
                EMapEntry spread = {.key = NULL, .value = src_res.value};
                list_push(EMapEntry, entries, spread);
                input = src_res.remaining;
                parser_result_t sc = parse_symbol(input, ',');
                if (sc.is_some) {
                    input = sc.remaining;
                    continue;
                }
                input = sc.remaining;
                break;
            }
        }
        parser_result_t key_res = parse_identifier(input);
        if (!key_res.is_some) { break; }
        input = key_res.remaining;
        Expr *value_node = NULL;
        parser_result_t re = parse_symbol(input, ':');
        input = re.remaining;
        if (!re.is_some) {
            // shorthand for {key: key}
            value_node = (Expr *)malloc(sizeof(Expr));
            value_node->kind = EXPR_EVAR;
            value_node->as.evar = strdup((char *)key_res.value);
        } else {
            ast_parser_result_t value_res = ast__parse_expr(input);
            if (!value_res.is_some) {
                free(key_res.value);
                goto _L_PARSE_MAP_FAILED;
            }
            input = value_res.remaining;
            value_node = value_res.value;
        }
        EMapEntry entry = {
            .key = (char *)key_res.value,
            .value = value_node,
        };
        list_push(EMapEntry, entries, entry);
        parser_result_t comma_res = parse_symbol(input, ',');
        if (comma_res.is_some) {
            input = comma_res.remaining;
        } else {
            break;
        }
    }
    EXPECT_SYMBOL('}', goto _L_PARSE_MAP_FAILED;);
    Expr *map_node = (Expr *)malloc(sizeof(Expr));
    map_node->kind = EXPR_EMAP;
    map_node->as.map_node.count = list_count(entries);
    map_node->as.map_node.entries = entries;
    return asome(map_node, input);
}

ast_parser_result_t ast_parse_array(const char *input) {
    // works like this
    // [value, value, ...]
    const char *original_input = input;
    EXPECT_SYMBOL('[', );
    LIST(Expr *) elements = NULL;
    list_init(Expr *, elements);
    while (1) {
        ast_parser_result_t elem_res = ast__parse_expr(input);
        if (!elem_res.is_some) { break; }
        input = elem_res.remaining;
        list_push(Expr *, elements, elem_res.value);
        EXPECT_SYMBOL(',', { break; });
    }
    EXPECT_SYMBOL(']', {
        for (size_t i = 0; i < list_count(elements); i++) {
            ast_free(list_get(elements, i));
        }
        list_free(elements);
        return anone(original_input);
    });
    Expr *array_node = (Expr *)malloc(sizeof(Expr));
    array_node->kind = EXPR_EARRAY;
    array_node->as.array_node.count = list_count(elements);
    array_node->as.array_node.elements = elements;
    return asome(array_node, input);
}

ast_parser_result_t ast__parse_first(const ast_parser_t *parsers,
                                     const char *input) {
    SKIP_SPACES;
    while (*parsers) {
        ast_parser_result_t res = (*parsers)(input);
        if (res.is_some) { return res; }
        parsers++;
    }
    return anone(input);
}

#define __EXPR_BLOCK_PARSERS ast_parse_brace_block

#define __EXPR_INLINE_PARSERS                                                  \
    ast_parse_return, ast_parse_function, ast_parse_binary_op,                 \
        ast_parse_map, ast_parse_brace_block, ast_parse_array,                 \
        ast_parse_unary, ast_parse_function_call, ast_parse_paren_expr,        \
        ast_parse_if, ast_parse_while, ast_parse_foreach, ast_parse_for,       \
        ast_parse_declaration, ast_parse_number, ast_parse_string,             \
        ast_parse_array_idx, ast_parse_true_false, ast_parse_variable

const ast_parser_t EXPR_BLOCK_PARSERS[] = {__EXPR_BLOCK_PARSERS, NULL};
const ast_parser_t EXPR_INLINE_PARSERS[] = {__EXPR_INLINE_PARSERS, NULL};
const ast_parser_t EXPR_PARSERS[] = {__EXPR_INLINE_PARSERS,
                                     __EXPR_BLOCK_PARSERS, NULL};
const ast_parser_t EXPR_ALLOWED_BIN_OPS[] = {ast_parse_unary,
                                             ast_parse_paren_expr,
                                             ast_parse_function_call,
                                             ast_parse_array_idx,
                                             ast_parse_map,
                                             ast_parse_array,

                                             ast_parse_number,
                                             ast_parse_string,
                                             ast_parse_true_false,
                                             ast_parse_variable,
                                             NULL};

ast_parser_result_t ast__parse_expr(const char *input) {
    return ast__parse_first(EXPR_PARSERS, input);
}

ast_parser_result_t ast__parse_inline_expr(const char *input) {
    return ast__parse_first(EXPR_INLINE_PARSERS, input);
}

ast_parser_result_t ast__parse_inside_binary_op(const char *input) {
    return ast__parse_first(EXPR_ALLOWED_BIN_OPS, input);
}

/**
Guaranteed to not return anone, will return asome with value NULL if no
expressions are found
*/
ast_parser_result_t ast_parse_expr_block(const char *input) {
    const char *original_input = input;
    Expr **list = NULL;
    size_t count = 0;
    while (1) {
        ast_parser_result_t res = ast__parse_expr(input);
        if (!res.is_some) { break; }
        list = (Expr **)realloc(list, sizeof(Expr *) * (count + 1));
        list[count] = res.value;
        count++;
        input = res.remaining;
        input = skip_spaces(input);
        if (*input == ';') {
            input++;
        } else {
            break;
        }
    }
    if (count == 0) { return anone(original_input); }
    Expr *block = (Expr *)malloc(sizeof(Expr));
    block->kind = EXPR_EBLOCK;
    block->as.block_node.exprs = list;
    block->as.block_node.count = count;
    return asome(block, input);
}