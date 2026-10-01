/* native.h — the emitter (1:1 port of src/y/native.y).
 *
 * native.y's `export { emit_program, std_units, std_unit_names, std_pack,
 * native_resolve, native_resolve_x, origin_at, strip_ns, strip_list,
 * strip_decl, phase_end };` — exactly those names.
 */
#ifndef NATIVE_H
#define NATIVE_H

#include "yv.h"

Yv *native_resolve(Yv *src, Yv *base_dir, long depth);
Yv *native_resolve_x(Yv *src, Yv *base_dir, long depth, int allow_exec,
                     Yv *root);
Yv *std_units(Yv *names, Yv *pack);
Yv *std_unit_names(void);
Yv *std_pack(Yv *units);
Yv *origin_at(Yv *o, long ln, int bare);
Yv *strip_ns(Yv *node, Yv *imports);
Yv *strip_list(Yv *nodes, Yv *imports);
Yv *strip_decl(Yv *node, Yv *imports);
Yv *phase_end(Yv *times, Yv *name, long t0, long h0);
Yv *emit_program(Yv *ast, Yv *imports, Yv *origin, int debug, Yv *std);

#endif /* NATIVE_H */
