/* pkg.h — exported surface of pkg.c, the 1:1 port of src/y/pkg.y. */
#ifndef PKG_H
#define PKG_H

#include "yv.h"

Yv *pk_load(Yv *dir);
long pk_vendor(Yv *dir);
Yv *pk_join(Yv *dir, Yv *p);
Yv *pk_dir_of(Yv *path);
long pk_mkdir(Yv *path);
int pk_has(Yv *xs, Yv *s);
Yv *pk_hash_new(void);
long pk_hash_str(Yv *h, Yv *s);
Yv *pk_hash_text(Yv *h);
Yv *pk_self_id(void);
long pk_exec(Yv *cmd);       /* exec(cmd): fork, /bin/sh -c, wait4 */
int pk_exists(Yv *path);     /* exists(path) */

#endif /* PKG_H */
