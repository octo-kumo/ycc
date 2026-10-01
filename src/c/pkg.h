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

#endif /* PKG_H */
