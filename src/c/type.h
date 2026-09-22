#ifndef TYPE_H
#define TYPE_H
#include "list.h"
#include <stddef.h>
typedef enum {
    VAL_LONG,
    VAL_FLOAT,
    VAL_ARR,
    VAL_MAP,
    VAL_BOOL,
    VAL_STR,
    VAL_FUNC,
    VAL_TYPE, // the type of a type, used for type annotations like "type of x"
    VAL_NULL,
    _VAL_INFERRED, // used for type inference, should never appear in actual
                   // types
} ValueType;
struct VMValue;

typedef struct type_map_entry_t {
    char key[32]; // allow maximum 32 chars for map entry name, so this may
                  // store "id" or "name"
    struct type_t *value;
} type_map_entry_t;

typedef struct type_t {
    ValueType base;
    union {
        size_t number;
        struct {
            size_t param_count;
            LIST(struct type_t *) param_types;
            struct type_t *return_type;
        } func;
        struct {
            struct type_t *element_type;
        } array;
        struct {
            size_t count;
            struct type_map_entry_t *entries;
        } map;
        struct type_t *type; // this is a type of a value which is a type
    } as;
} type_t;
type_t *tc_make_t(ValueType base);

extern type_t *_TYPE_INFERRED;
extern type_t *_TYPE_INFERRED_ARRAY;
extern type_t *TYPE_NULL;
extern type_t *TYPE_LONG;
extern type_t *TYPE_FLOAT;
extern type_t *TYPE_BOOL;
extern type_t *TYPE_STR;
size_t type_t_to_buf(type_t *t, char *buf, size_t buf_size);
char *type_t_to_str(type_t *t);
#endif