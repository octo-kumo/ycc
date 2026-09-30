// arch_x64.h — Linux x86_64 code emitters for the native backend (ycc).
// C twin of src/y/arch_x64.y (see PORTING.md). Exports exactly the Y
// module's top-level defs, per its export list:
//   export { arch_id, arch_word, arch_sysno, arch_fn_label, arch_loc_label,
//            arch_str_label, arch_header, arch_rodata, arch_text,
//            arch_prelude, arch_consts, arch_frame, arch_exit };
#ifndef ARCH_X64_H
#define ARCH_X64_H

#include "yv.h"

Yv *arch_id(void);
long arch_word(void);
long arch_sysno(Yv *name);
Yv *arch_fn_label(long uid, Yv *name);
Yv *arch_loc_label(long fuid, long n);
Yv *arch_str_label(long i);
Yv *arch_header(void);
Yv *arch_rodata(void);
Yv *arch_text(void);
Yv *arch_prelude(void);
Yv *arch_consts(void);
long arch_frame(long slots);
Yv *arch_exit(void);

#endif /* ARCH_X64_H */
