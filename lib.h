#ifndef LIB_H
#define LIB_H
#include "typecheck.h"
#include "vm.h"
void populate_types(TCVarTypeScope *scope);
void populate_scope(VMVariableScope *scope);
void vm_set_argv(int argc, char **argv);
#endif