/* types.h — the static checker's exported surface (src/y/types.y `export`).
 *
 * The C compiler (src/c) is a 1:1 copy of the Y compiler (src/y); this
 * header exports exactly types.y's `export { check_program, tstr, tdisp,
 * tdisp_fnval, teq, field_merge }`. Every other def of the module is
 * private to types.c (the Y module keeps them unexported the same way).
 */
#ifndef TYPES_H
#define TYPES_H

#include "yv.h"

Yv *check_program(Yv *ast);   /* -> [{ msg, line, col }] ([] means OK) */
Yv *tstr(Yv *t);              /* compiler-diagnostics rendering of a type */
Yv *tdisp(Yv *t);             /* user-visible rendering (typeof) */
Yv *tdisp_fnval(Yv *t);       /* "<function (params)->(ret)>" shape */
int teq(Yv *a, Yv *b);        /* strict type equality (branch agreement) */
Yv *field_merge(Yv *fields, Yv *name, Yv *typ);  /* record-literal upsert */
Yv *narrow_type(Yv *s, Yv *t); /* static type of a match `narrow` node */
Yv *type_names(Yv *t);        /* field names a record type / pattern tests */

#endif /* TYPES_H */
