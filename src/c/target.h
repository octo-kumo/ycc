/* target.h — which target the compiler emits for, as one global.
 * 1:1 C copy of src/y/target.y (see PORTING.md).
 *
 * The whole compiler is ONE product that emits either an ELF (the default)
 * or a Windows PE, chosen by ycc --target. Three consumers read it, in
 * three different ways (ideas/WINDOWS.md, "The target reaches three
 * places):
 *
 *   asm.c       -- picks the object writer at link time (elf_build or
 *                  pe_build; both are linked in and their names and types
 *                  differ, so no splicer involvement);
 *   arch_x64.c  -- dispatches inside itself on target_is_windows(),
 *                  because a second arch *file* cannot coexist (a path
 *                  import is flattened into its importer, so arch_frame
 *                  would be defined twice and the second would win);
 *   native.c    -- the entry point, the syscall convention and the ABI.
 *
 * WHY A MODULE OF ITS OWN rather than a static in native.c: native.c's
 * own top-levels are spliced AFTER the modules it imports (asm.c among
 * them), so a global declared there would be read before it is
 * declared. This file is imported first of all in ycc.c, so every reader
 * sees the binding first.
 *
 * The name is res_* like native.c's res_pkgs/res_used: ambient state the
 * pipeline threads by hand, not an argument.
 */
#ifndef TARGET_H
#define TARGET_H

#include "ylong.h"
#include "yv.h"

/* the Y twin's `let res_target = "linux";` — a Yv * global, because every
   comparison in the Y code is a string compare. */
extern Yv *res_target;
void target_set(Yv *name);

/* True when the target is Windows. Every target test in the tree goes
   through this one predicate, so a third target is a change here first. */
int target_is_windows(void);

/* The target name as a program sees it, for the `target` and `os` builtin
   constants the checker binds (types.c). Kept next to the global so the
   name a flag accepts and the name a program reads cannot drift apart. */
Yv *target_os(void);

#endif /* TARGET_H */