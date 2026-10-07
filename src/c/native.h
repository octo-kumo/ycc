/* native.h — the emitter (1:1 port of src/y/native.y).
 *
 * native.y's `export { emit_program, compile_package, std_units,
 * std_unit_names, std_pack, unit_obj, unit_unobj, unit_iface,
 * native_resolve, native_resolve_x, native_resolve_pk, origin_at,
 * strip_ns, strip_list, strip_decl, phase_end, link_text, is_intrinsic_name,
 * intrinsic_names };` — exactly those
 * names.
 */
#ifndef NATIVE_H
#define NATIVE_H

#include "ylong.h"
#include "yv.h"

Yv *native_resolve(Yv *src, Yv *base_dir, ylong depth);
Yv *native_resolve_x(Yv *src, Yv *base_dir, ylong depth, int allow_exec,
                     Yv *root);
Yv *native_resolve_pk(Yv *src, Yv *base_dir, int allow_exec, Yv *root,
                      Yv *pkgs, Yv *roots);
Yv *std_units(Yv *names, Yv *pack);
Yv *std_unit_names(void);
Yv *std_pack(Yv *units);
Yv *compile_package(Yv *ast, Yv *nr, Yv *name, ylong base, ylong wlevel,
                    Yv *std, Yv *deps);
Yv *unit_obj(Yv *unit, Yv *key);
Yv *unit_unobj(Yv *text, Yv *key);
Yv *unit_iface(Yv *unit);
Yv *origin_at(Yv *o, ylong ln, int bare);
Yv *strip_ns(Yv *node, Yv *imports);
Yv *strip_list(Yv *nodes, Yv *imports);
Yv *strip_decl(Yv *node, Yv *imports);
Yv *phase_end(Yv *times, Yv *name, ylong t0, ylong h0);
Yv *emit_program(Yv *ast, Yv *nr, int debug, ylong wlevel, Yv *std,
                    Yv *deps);
/* The parts emit_program returned, rendered as assembly text: what -S
 * prints. The assembler takes the parts themselves. */
Yv *link_text(Yv *parts);
/* The builtins, tested and enumerated. Exported for the language server's
 * completion list: it must offer exactly the compiler's set, so it reads this
 * list rather than keeping its own copy (see native.c's intrinsics). */
int is_intrinsic_name(Yv *n);
Yv *intrinsic_names(void);

#endif /* NATIVE_H */
/* --gc: 0 auto, 1 always, 2 never (native.y's set_gc_mode). */
void set_gc_mode(ylong m);
