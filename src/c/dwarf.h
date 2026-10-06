/* dwarf.h — DWARF 4 line information for ycc -g (1:1 port of dwarf.y). */
#ifndef DWARF_H
#define DWARF_H

#include "ylong.h"
#include "yv.h"

Yv *dwarf_sections(Yv *files, Yv *rows, ylong text_addr, ylong text_len,
                   Yv *comp_dir);

#endif /* DWARF_H */
