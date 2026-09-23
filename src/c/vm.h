#ifndef VM_H
#define VM_H

#include "ast.h"
#include "map.h"
#include "stdbool.h"
#include "type.h"
#include <stddef.h>

typedef struct VMArray {
    int refcount;      /* shared: clones share this array (see val_clone) */
    size_t count;
    size_t capacity;   /* allocated slots (>= count); O(1) amortized push */
    struct VMValue **elements;
} VMArray;

typedef struct VMMapEntry {
    char *key;
    struct VMValue *value;
} VMMapEntry;
typedef struct VMMap {
    int refcount;      /* shared: clones share this map (see val_clone) */
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
        struct VMClosure *closure;
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
    int refcount;    // heap-allocated, reference-counted (for closures)
} VMVariableScope;

/* A closure pairs a function's AST with the lexical scope it was defined in. */
typedef struct VMClosure {
    Expr *func;             /* EXPR_EFUNC node (not owned) */
    VMVariableScope *scope; /* captured defining scope (retained) */
} VMClosure;

VMValue *vm_scope_get(VMVariableScope *scope, const char *name);
void vm_scope_set(VMVariableScope *scope, const char *name, VMValue *value);
void vm_scope_set_local(VMVariableScope *scope, const char *name,
                        VMValue *value);
VMVariableScope *vm_scope_new(VMVariableScope *parent);
VMVariableScope *vm_scope_retain(VMVariableScope *scope);
void vm_scope_release(VMVariableScope *scope);
VMValue *vm_mk_external_func(Expr *func_expr);

typedef struct {
    VMVariableScope *globals;
} VM;
void val_print(const VMValue *val);
char *val_to_str(const VMValue *val);
type_t *val_type(const VMValue *val);
void val_free(VMValue *val);
VMValue *val_clone(const VMValue *val);
/* Allocate a fresh (unshared) array/map body: refcount 1, empty. Every
 * VMArray/VMMap must come from these so the refcount is always valid. */
VMArray *vm_arr_alloc(void);
VMMap *vm_map_alloc(void);
void vm_init(VM *vm);
VMValue *vm_execute(VMVariableScope *scope, Expr *expr);
void vm_scope_free(VMVariableScope *scope);
VMValue *nval(ValueType type);

#endif // VM_H