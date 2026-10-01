/* elf.h — minimal ELF64 writer for ycc output.
 * 1:1 C copy of src/y/elf.y (see PORTING.md).
 * One PT_LOAD segment (read+execute), static, no interpreter, no libc;
 * programs with globals get a second zero-filled read+write .bss segment.
 * Bytes are plain longs (0-255) in Y lists ([long] -> Yv * of boxed longs). */
#ifndef ELF_H
#define ELF_H

#include "yv.h"

long elf_code_off(long bss_len);
long elf_bss_from_ro(long ro_len, long bss_len);
Yv *elf_build(Yv *code, Yv *rodata, long entry_off, long bss_len, Yv *syms,
              Yv *dsecs);
                     /* ([long], [long], long, long, [symbol], [section]) -> [long] */
Yv *elf_debug(long code_off, long codesz, long codepad, long ro_len,
              long total, long bss_len, Yv *syms, Yv *dsecs);
Yv *push_sym(Yv *out, long name_off, Yv *sy, long bss_idx, long text_addr,
             long bss_addr, long bind);
Yv *push_shdr(Yv *out, long name, long typ, long flags, long addr, long off,
              long size, long link, long info, long align, long entsize);
Yv *push_cstr(Yv *out, Yv *s);
Yv *push_zeros(Yv *out, long n);
Yv *push_bytes(Yv *out, Yv *bytes); /* (out: [long], bytes: [long]) -> [long] */
Yv *push_le16(Yv *out, long v);     /* (out: [long], v: long) -> [long] */
Yv *push_le32(Yv *out, long v);     /* (out: [long], v: long) -> [long] */
Yv *push_le64(Yv *out, long v);     /* (out: [long], v: long) -> [long] */

#endif /* ELF_H */
