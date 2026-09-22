#include "type.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ill never free them, they will be freed when the program exits, and this is a
// small compiler, so its fine

type_t type_t_registry[10000];
size_t type_t_registry_count = 0;

type_t *tc_make_t(ValueType base) {
    if (type_t_registry_count >= 1000) {
        fprintf(stderr, "Type registry overflow\n");
        exit(1);
    }
    type_t *t = &type_t_registry[type_t_registry_count++];
    t->base = base;
    return t;
}

// primitive types
// special marker for type inference
type_t *_TYPE_INFERRED = &(type_t){.base = _VAL_INFERRED};
type_t *_TYPE_INFERRED_ARRAY = &(type_t){
    .base = VAL_ARR, .as.array.element_type = &(type_t){.base = _VAL_INFERRED}};
type_t *TYPE_NULL = &(type_t){.base = VAL_NULL};
type_t *TYPE_LONG = &(type_t){.base = VAL_LONG, .as.number = 64};
type_t *TYPE_FLOAT = &(type_t){.base = VAL_FLOAT, .as.number = 64};
type_t *TYPE_BOOL = &(type_t){.base = VAL_BOOL};
type_t *TYPE_STR = &(type_t){.base = VAL_STR};
size_t type_t_to_buf(type_t *t, char *buf, size_t buf_size) {
    if (!t || !buf || buf_size == 0) return 0;

    switch (t->base) {
    case VAL_LONG: return snprintf(buf, buf_size, "long");
    case VAL_FLOAT: return snprintf(buf, buf_size, "float");
    case VAL_BOOL: return snprintf(buf, buf_size, "bool");
    case VAL_STR: return snprintf(buf, buf_size, "str");
    case VAL_NULL: return snprintf(buf, buf_size, "null");

    case VAL_ARR: {
        char inner[256]; // Temporary stack buffer for recursion
        type_t_to_buf(t->as.array.element_type, inner, sizeof(inner));
        return snprintf(buf, buf_size, "[%s]", inner);
    }

    case VAL_MAP: {
        size_t offset = snprintf(buf, buf_size, "{");
        for (size_t i = 0; i < t->as.map.count; i++) {
            char val_str[256];
            type_t_to_buf(t->as.map.entries[i].value, val_str, sizeof(val_str));

            offset += snprintf(buf + offset, buf_size - offset, "%s%s: %s",
                               (i > 0 ? ", " : ""), t->as.map.entries[i].key,
                               val_str);
            if (offset >= buf_size) break;
        }
        if (offset < buf_size)
            offset += snprintf(buf + offset, buf_size - offset, "}");
        return offset;
    }

    case VAL_FUNC: {
        size_t offset = snprintf(buf, buf_size, "(");
        for (size_t i = 0; i < t->as.func.param_count; i++) {
            char p_str[256];
            type_t_to_buf(t->as.func.param_types[i], p_str, sizeof(p_str));
            offset += snprintf(buf + offset, buf_size - offset, "%s%s",
                               (i > 0 ? ", " : ""), p_str);
            if (offset >= buf_size) break;
        }
        char ret_str[256];
        type_t_to_buf(t->as.func.return_type, ret_str, sizeof(ret_str));
        offset += snprintf(buf + offset, buf_size - offset, ")->%s", ret_str);
        return offset;
    }
    case VAL_TYPE:
        return snprintf(buf, buf_size, "type(%s)", type_t_to_str(t->as.type));
    case _VAL_INFERRED: return snprintf(buf, buf_size, "<inferred>");
    }
    return 0;
}
char *type_t_to_str(type_t *t) {
    static char static_buffer[2048];
    type_t_to_buf(t, static_buffer, sizeof(static_buffer));
    return static_buffer;
}