/* elf.h — minimal ELF64 writer for ycc output.
 * 1:1 C copy of src/y/elf.y (see PORTING.md).
 * One PT_LOAD segment (read+execute), static, no interpreter, no libc;
 * programs with globals get a second zero-filled read+write .bss segment.
 * Bytes are plain longs (0-255) in Y lists ([long] -> Yv * of boxed longs). */
#ifndef ELF_H
#define ELF_H

#include "ylong.h"
#include "yv.h"

ylong elf_code_off(ylong bss_len);
ylong elf_bss_from_ro(ylong code_len, ylong ro_len);
Yv *elf_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len, Yv *syms,
              Yv *dsecs);
                     /* ([long], [long], long, long, [symbol], [section]) -> [long] */
Yv *elf_debug(ylong code_off, ylong codesz, ylong codepad, ylong ro_len,
              ylong total, ylong bss_len, Yv *syms, Yv *dsecs);
Yv *push_sym(Yv *out, ylong name_off, Yv *sy, ylong bss_idx, ylong text_addr,
             ylong bss_addr, ylong bind);
Yv *push_shdr(Yv *out, ylong name, ylong typ, ylong flags, ylong addr, ylong off,
              ylong size, ylong link, ylong info, ylong align, ylong entsize);
Yv *push_cstr(Yv *out, Yv *s);
Yv *push_zeros(Yv *out, ylong n);
Yv *push_bytes(Yv *out, Yv *bytes); /* (out: [long], bytes: [long]) -> [long] */
Yv *push_le16(Yv *out, ylong v);     /* (out: [long], v: long) -> [long] */
Yv *push_le32(Yv *out, ylong v);     /* (out: [long], v: long) -> [long] */
Yv *push_le64(Yv *out, ylong v);     /* (out: [long], v: long) -> [long] */

#endif /* ELF_H */
