// target.c — which target the compiler emits for, as one global.
// 1:1 port of src/y/target.y (see PORTING.md). The comment that matters
// is in target.h: the module exists so every reader sees the binding
// before it is read, and so a third target is a change here first.
#include "target.h"

/* `let res_target = "linux";` — the Y twin's top-level initialiser.

   The C twin starts it at NULL and reads NULL as the default, which is the
   same value and the same rule: `res_target == "windows"` is false for both
   NULL and "linux", so target_is_windows needs no special case and
   target_os answers "linux" for either. This is the shape src/c/rename.c's
   `rn_mod` uses for the same thing (a top-level `let` with a value, read
   before anything writes it), and the reason is that a file-scope initialiser
   in C must be a constant expression while ys() is not. */
Yv *res_target = 0;

void target_set(Yv *name) {
    res_target = name;
}

/* def target_is_windows() -> bool { res_target == "windows" } */
int target_is_windows(void) {
    return res_target != 0 && ys_eq_lit(res_target, "windows");
}

/* def target_os() -> str { if (res_target == "windows") { "windows" } else
   { "linux" } } */
Yv *target_os(void) {
    if (target_is_windows()) { return ys("windows"); }
    else { return ys("linux"); }
}