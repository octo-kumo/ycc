// arch_x64.h — Linux x86_64 code emitters for the native backend (ycc).
// C twin of src/y/arch_x64.y (see PORTING.md). Exports exactly the Y
// module's top-level defs, per its export list:
//   export { arch_id, arch_word, arch_sysno, arch_fn_label, arch_loc_label,
//            arch_str_label, arch_header, arch_rodata, arch_text,
//            arch_bss, arch_global_cell, arch_heap_cells, arch_kernel_bss,
//            arch_prelude_lines, arch_prelude_threads_lines, arch_math_lines,
//            kernel_irq_text, arch_consts, arch_frame, arch_exit };
#ifndef ARCH_X64_H
#define ARCH_X64_H

#include "ylong.h"
#include "yv.h"

Yv *arch_id(void);
ylong arch_word(void);
ylong arch_sysno(Yv *name);
Yv *arch_fn_label(ylong uid, Yv *name);
Yv *arch_global_label(ylong uid, Yv *name);
Yv *arch_loc_label(ylong fuid, ylong n);
Yv *arch_str_label(ylong i);
Yv *arch_header(void);
Yv *arch_rodata(void);
Yv *arch_text(void);
Yv *arch_bss(void);
Yv *arch_global_cell(Yv *label);
Yv *w_imports(void);
Yv *w_iat_label(Yv *fn);
Yv *w_iat_term_label(Yv *dll);
Yv *w_iat_bss_lines(void);
ylong w_iat_offset(ylong d, ylong f);
Yv *arch_heap_cells(void);
Yv *arch_kernel_bss(void);
Yv *kernel_irq_text(void);
Yv *arch_prelude_lines(void);
Yv *arch_prelude_threads_lines(void);
Yv *arch_math_lines(void);
Yv *w_self_test_lines(void);
Yv *arch_consts(void);
ylong arch_frame(ylong slots);
Yv *arch_exit(void);

#endif /* ARCH_X64_H */
