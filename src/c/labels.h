/* labels.h -- the label identity table (1:1 C copy of src/y/labels.y, see
 * PORTING.md). A label is a long: an index into one array of names, so the
 * emitter compares labels as integers and builds a name only where text is
 * wanted (the emitted line, -S, -g's symbols, the pack, a diagnostic). */
#ifndef LABELS_H
#define LABELS_H

#include "yv.h"

Yv *lbl_new(Yv *name);    /* intern: one id per name */
Yv *lbl_fresh(Yv *name);  /* a name no one else can name: no interning */
Yv *lname(Yv *id);        /* the name; "" for -1 */

#endif