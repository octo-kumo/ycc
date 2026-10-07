// target.c — which target the compiler emits for, as one global.
// 1:1 port of src/y/target.y (see PORTING.md). The comment that matters
// is in target.h: the module exists so every reader sees the binding
// before it is read, and so a third target is a change here first.
#include "ylong.h"
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

/* ── the kernel's IRQ declarations ───────────────────────────────────────
   `irq N def f() -> void { ... }` is a top-level declaration that exists
   only for `--kernel` (parser.c: parse_irq_def, gated on target_is_kernel so
   `irq` stays an ordinary identifier everywhere else).  It is the language's
   IRQ handler: the vector is bound at the declaration, the checker enforces
   the signature, and the emitter generates the interrupt stub that saves the
   caller-saved registers, calls `f`, acknowledges the 8259s and `iretq`s.

   Two lists, filled at three different times, which is why they are here
   rather than in one pass:
     res_irqs      parser: (line, the def's name as written)
     res_irq_stubs emitter: (line, the def's emitted label), once the hoisted
                   defs have their labels
   The name/line pair is what the checker validates against; the label is what
   the generated stub calls.  A KernelIrq is the record { line, name } and a
   KernelIrqStub the record { line, label } (PORTING.md rule 3). */
Yv *res_irqs = 0;
Yv *res_irq_stubs = 0;

/* NOTE: the lookups below are index loops rather than `foreach`.  A foreach
   closure that compares its ELEMENT to a CAPTURED value answers false in the
   Y twin (`xs.foreach((x) => { if (x == v) { d = true; }; })` never sets d,
   whatever v is; `x == 4` and reading `v` both work), which is a pre-existing
   bug -- it reproduces with refs/ycc.ref -- and not one this work is here to
   fix.  The kernel's IRQ path therefore does not use that shape. */

void target_set(Yv *name) {
    res_target = name;
}

/* def target_is_kernel() -> bool { res_target == "kernel" } */
int target_is_kernel(void) {
    return res_target != 0 && ys_eq_lit(res_target, "kernel");
}

/* def kernel_irq_line(name: str) -> long: the 8259 line a def is declared
   for, or -1: the one lookup every stage of the IRQ path goes through. */
ylong kernel_irq_line(Yv *name) {
    ylong out = -1;
    ylong i = 0;
    while (i < yv_len(res_irqs)) {
        Yv *e = ya_get(res_irqs, i);
        if (ys_eq(yr_get(e, "name"), name)) { out = yv_l(yr_get(e, "line")); };
        i++;
    };
    return out;
}

/* def kernel_irq_stub(line: long, label: str) -> void: record a handler's
   emitted label, replacing any earlier entry for the same line.  A unit that
   is emitted twice must not produce two stubs for one vector (the
   assembler's duplicate-label error is the only other symptom). */
void kernel_irq_stub(ylong line, Yv *label) {
    Yv *out = yav(0);
    int done = 0;
    ylong i = 0;
    while (i < yv_len(res_irq_stubs)) {
        Yv *e = ya_get(res_irq_stubs, i);
        if (yv_l(yr_get(e, "line")) == line && !done) {
            out = ya_push(out, yr(2, "line", yv_long(line), "label", label));
            done = 1;
        } else {
            out = ya_push(out, e);
        };
        i++;
    };
    if (!done) { out = ya_push(out, yr(2, "line", yv_long(line), "label", label)); };
    res_irq_stubs = out;
}

/* def target_is_windows() -> bool { res_target == "windows" } */
int target_is_windows(void) {
    return res_target != 0 && ys_eq_lit(res_target, "windows");
}

/* def target_os() -> str { if (res_target == "windows") { "windows" } else
   if (res_target == "kernel") { "kernel" } else { "linux" } } */
Yv *target_os(void) {
    if (target_is_windows()) { return ys("windows"); }
    else if (target_is_kernel()) { return ys("kernel"); }
    else { return ys("linux"); }
}