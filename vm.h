#ifndef VM_H
#define VM_H

#include "ast.h"
#include "map.h"
#include "stdbool.h"
#include "type.h"
#include <stddef.h>

typedef struct VMArray {
    size_t count;
    struct VMValue **elements;
} VMArray;

typedef struct VMMapEntry {
    char *key;
    struct VMValue *value;
} VMMapEntry;
typedef struct VMMap {
    size_t count;
    VMMapEntry *entries;
} VMMap;

typedef struct VMValue {
    ValueType type;
    union {
        long l;
        double f;
        bool b;
        char *s;
        Expr *func;
        VMArray *arr;
        VMMap *map;
        type_t *type;
    } data;
} VMValue;

typedef struct {
    char *name;
    VMValue value;
} VMVariable;

struct VMVariableScope;
typedef struct VMVariableScope {
    struct VMVariableScope *parent;
    map_t variables; // Map of variable name to Variable
} VMVariableScope;
VMValue *vm_scope_get(VMVariableScope *scope, const char *name);
void vm_scope_set(VMVariableScope *scope, const char *name, VMValue *value);

typedef struct {
    VMVariableScope globals;
} VM;
void val_print(const VMValue *val);
char *val_to_str(const VMValue *val);
type_t *val_type(const VMValue *val);
void val_free(VMValue *val);
VMValue *val_clone(const VMValue *val);
void vm_init(VM *vm);
VMValue *vm_execute(VMVariableScope *scope, Expr *expr);
void vm_scope_free(VMVariableScope *scope);
VMValue *nval(ValueType type);

#endif // VM_H