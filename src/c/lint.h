/* lint.h — exported surface of lint.c, the 1:1 port of src/y/lint.y. */
#ifndef LINT_H
#define LINT_H

#include "yv.h"

/* [{ msg, line, col }]: the warnings for one unit, sorted by position. */
Yv *lint_unit(Yv *ast, Yv *ast3);

#endif /* LINT_H */
