/* native.h — the emitter (1:1 port of src/y/native.y).
 *
 * native.y's `export { emit_program, compile_package, std_units,
 * std_unit_names, std_pack, unit_obj, unit_unobj, unit_iface,
 * native_resolve, native_resolve_x, native_resolve_pk, origin_at,
 * strip_ns, strip_list, strip_decl, phase_end };` — exactly those names.
 */
#ifndef NATIVE_H
#define NATIVE_H

#include "yv.h"

Yv *native_resolve(Yv *src, Yv *base_dir, long depth);
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     Yv *root);
Yv *native_resolve_pk(Yv *src, Yv *base_dir, int allow_exec, Yv *root,
                      Yv *pkgs, Yv *roots);
Yv *std_units(Yv *names, Yv *pack);
Yv *std_unit_names(void);
Yv *std_pack(Yv *units);
Yv *compile_package(Yv *ast, Yv *nr, Yv *name, long base, long wlevel,
                    Yv *std, Yv *deps);
Yv *unit_obj(Yv *unit, Yv *key);
Yv *unit_unobj(Yv *text, Yv *key);
Yv *unit_iface(Yv *unit);
Yv *origin_at(Yv *o, long ln, int bare);
Yv *strip_ns(Yv *node, Yv *imports);
Yv *strip_list(Yv *nodes, Yv *imports);
Yv *strip_decl(Yv *node, Yv *imports);
Yv *phase_end(Yv *times, Yv *name, long t0, long h0);
Yv *emit_program(Yv *ast, Yv *nr, int debug, long wlevel, Yv *std,
                    Yv *deps);

#endif /* NATIVE_H */
