#ifndef LIB_H
#define LIB_H
#include "typecheck.h"
#include "vm.h"
void populate_types(TCVarTypeScope *scope);
void populate_scope(VMVariableScope *scope);
void vm_set_argv(int argc, char **argv);

/* Security switch: when set, the `exec` builtin (system() escape hatch) is
 * not registered in the type scope, the VM scope, or emitted C output, so
 * programs cannot shell out. Honored by populate_types/populate_scope and
 * the codegen backend. Set via the ycc `--no-exec` CLI flag. */
extern int g_exec_disabled;
void set_exec_disabled(int disabled);
#endif