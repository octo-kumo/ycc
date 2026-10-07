/* kelf.h — the ELF32 Multiboot-1 writer for `ycc --kernel`.
 * 1:1 C copy of src/y/kelf.y (see PORTING.md).
 *
 * A kernel image is a different object FORMAT, not just a different base: the
 * boot loaders that can start one (QEMU's `-kernel`, GRUB) speak Multiboot-1,
 * which is a 32-bit protected-mode ABI. The image is an ELF32 with a
 * Multiboot header in its first 8 KB, linked at 1 MB, whose entry point is
 * 32-bit code that switches the CPU to long mode and jumps into the 64-bit
 * payload the rest of the compiler emits (arch_x64.c's kernel head).
 *
 * Bytes are plain longs (0-255) in Y lists ([byte] -> Yv * of boxed longs),
 * like elf.h's.
 */
#ifndef KELF_H
#define KELF_H

#include "ylong.h"
#include "yv.h"

ylong kelf_base(void);
ylong kelf_code_off(void);
ylong kelf_head_len(void);
ylong kelf_img_memsz(ylong code_len, ylong ro_len);
ylong kelf_bss_from_ro(ylong code_len, ylong ro_len);
ylong kelf_bss_vaddr(ylong code_len, ylong ro_len);
Yv *kelf_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len);

#endif /* KELF_H */
