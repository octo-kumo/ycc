/* elf.h — minimal ELF64 writer for ycc output.
 * 1:1 C copy of src/y/elf.y (see PORTING.md).
 * One PT_LOAD segment (read+execute), static, no interpreter, no libc.
 * Bytes are plain longs (0-255) in Y lists ([long] -> Yv * of boxed longs). */
#ifndef ELF_H
#define ELF_H

#include "yv.h"

Yv *elf_build(Yv *code, Yv *rodata, long entry_off);
                     /* ([long], [long], long) -> [long] */
Yv *push_bytes(Yv *out, Yv *bytes); /* (out: [long], bytes: [long]) -> [long] */
Yv *push_le16(Yv *out, long v);     /* (out: [long], v: long) -> [long] */
Yv *push_le32(Yv *out, long v);     /* (out: [long], v: long) -> [long] */
Yv *push_le64(Yv *out, long v);     /* (out: [long], v: long) -> [long] */

#endif /* ELF_H */
