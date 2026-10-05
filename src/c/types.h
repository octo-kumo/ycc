/* types.h — the static checker's exported surface (src/y/types.y `export`).
 *
 * The C compiler (src/c) is a 1:1 copy of the Y compiler (src/y); this
 * header exports types.y's `export { check_program, tstr, teq, field_merge,
 * narrow_type, type_names, str_method, fmt_spec, fmt_kind }`.
 * Every other def of the module is
 * private to types.c (the Y module keeps them unexported the same way).
 */
#ifndef TYPES_H
#define TYPES_H

#include "yv.h"

Yv *check_program(Yv *ast, Yv *ext); /* -> [{ msg, line, col }] ([] means OK) */
/* os_call_names(): the names std code may reach the kernel through -- the named
   syscall layer. Exported because native.c's check_os_call_names verifies that
   the arch lines really define each one, and that check has to see the list. */
Yv *os_call_names(void);

Yv *tstr(Yv *t);              /* the one rendering of a type: diagnostics,
                                * typeof, "<function (params) -> ret>" */
int teq(Yv *a, Yv *b);        /* strict type equality (branch agreement) */
long field_pos(Yv *fs, Yv *name, long hint); /* a field's index by name */
Yv *field_merge(Yv *fields, Yv *name, Yv *typ);  /* record-literal upsert */
Yv *str_method(Yv *m);        /* string-method lowering/type table */
Yv *narrow_type(Yv *s, Yv *t); /* static type of a match `narrow` node */
Yv *union_member(Yv *u, Yv *t); /* the member of union u that is t */
Yv *unfold(Yv *t);            /* a tref's type, one level */
Yv *members(Yv *t);           /* a union's members, unfolded */
Yv *union_parts(Yv *t);       /* a union's members as written */
Yv *pat_members(Yv *s, Yv *t); /* members with a record pattern's fields */
Yv *lit_target(Yv *node, Yv *want); /* a record literal's declared type */
int opt_wraps(Yv *vt, Yv *ft);       /* an optional field's plain value: some(v) */
Yv *t_mutex(void);                   /* the type `mutex` */
Yv *t_sem(void);                     /* the type `sem` */
Yv *tcanon(Yv *t);            /* a type's canonical form */
Yv *tsig(Yv *t);              /* its signature: recursive aliases by name */
Yv *inferred_ret(long line, long col); /* typeof_def's inferred return type */
Yv *str_sorted(Yv *xs);       /* [str] sorted */
Yv *rec_names(Yv *fs);        /* a record's field names, sorted */
Yv *type_names(Yv *t);        /* field names a record type / pattern tests */
Yv *fmt_spec(Yv *spec);       /* parsed f-string format specification */
long fmt_kind(Yv *t);          /* integer=1, float=2, other=0 */

#endif /* TYPES_H */
