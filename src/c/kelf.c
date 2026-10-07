/* kelf.c — the ELF32 Multiboot-1 writer for `ycc --kernel`.
 * 1:1 C copy of src/y/kelf.y (see PORTING.md).
 *
 * Two PT_LOAD segments, like the experiment in experiments/kernel/:
 *   1. R+X at 0x100000: the header, the trampoline, the code and the rodata.
 *      p_memsz is rounded up to a page; the tail is the loader's zero-fill.
 *   2. R+W, no file bytes at all: the .bss (globals, the heap arena, the IDT
 *      and the kernel stack), on the page after the image.
 * The writer and asm.c's `asm_bss_shift` must agree on where .bss starts --
 * they do, because both call kelf_bss_from_ro.
 *
 * No -g: the debug sections are ELF64/DWARF64 in this tree, and ycc refuses
 * the combination at the driver (ycc.c).
 *
 * Y-side binary data flows through packed [byte] arrays. The C value model
 * keeps each element as a boxed long; the driver writes it directly. */

#include "ylong.h"
#include "kelf.h"

/* imported — src/y/enc64.y (`import enc from "./enc64.y";`; module calls are
 * flattened, `enc.byte_of(v, i)` -> `byte_of(v, i)`). enc64.h has the
 * prototype: `def byte_of(v: long, i: long) -> long`. */
#include "enc64.h"

/* Where the payload is loaded. Multiboot says 1 MB, which is also where the
   linker puts it in the experiment, so the two can be diffed byte for byte. */
ylong kelf_base(void) {
    return 1048576;
}

/* The file offset of the code: ELF32 EHDR (52) plus two PHDR (32 each).
   arch_x64.c's trampoline bakes this in (its 32-bit code cannot ask the
   writer where it is), so it is a function here and both read it. */
ylong kelf_code_off(void) {
    return 116;
}

/* The 12-byte Multiboot header precedes `_start`; arch_x64.c's blob builder
   needs the same number to place the trampoline's own label. */
ylong kelf_head_len(void) {
    return 12;
}

static ylong kelf_round4k(ylong n) {
    ylong trail = n % 4096;
    if (trail != 0) { return n + 4096 - trail; } else { return n; }
}

/* The load image's size in memory, headers included: the code, the rodata and
   the 8-byte trailer (string helpers over-read past a trailing NUL), rounded
   up to a page. */
ylong kelf_img_memsz(ylong code_len, ylong ro_len) {
    return kelf_round4k(kelf_code_off() + code_len + ro_len + 8);
}

/* Where .bss starts, as an offset from the rodata's start -- the same shape as
   elf.c's elf_bss_from_ro, and the one asm_link rebases every .bss label by
   (asm_bss_shift). */
ylong kelf_bss_from_ro(ylong code_len, ylong ro_len) {
    return kelf_img_memsz(code_len, ro_len) - kelf_code_off() - code_len;
}

/* The bss segment's virtual address: the page after the loaded image. */
ylong kelf_bss_vaddr(ylong code_len, ylong ro_len) {
    return kelf_base() + kelf_img_memsz(code_len, ro_len);
}

/* ── little-endian field writers (the file has no libc and no buffer API) ── */
static Yv *kput16(Yv *out, ylong v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    out = ya_push(out, yv_long(byte_of(v, 1)));
    return out;
}

static Yv *kput32(Yv *out, ylong v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    out = ya_push(out, yv_long(byte_of(v, 1)));
    out = ya_push(out, yv_long(byte_of(v, 2)));
    out = ya_push(out, yv_long(byte_of(v, 3)));
    return out;
}

static Yv *kput8(Yv *out, ylong v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    return out;
}

/* ── the image ───────────────────────────────────────────────────────────── */
Yv *kelf_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len) {
    ylong base = kelf_base();
    ylong code_off = kelf_code_off();
    ylong codesz = yv_len(code);
    ylong ro_len = yv_len(rodata);
    ylong filesz = code_off + codesz + ro_len + 8;
    ylong memsz = kelf_img_memsz(codesz, ro_len);
    ylong bss_vaddr = kelf_bss_vaddr(codesz, ro_len);
    ylong entry = base + code_off + entry_off;
    ylong bss_sz = bss_len;
    if (bss_sz == 0) { bss_sz = 4096; };
    Yv *out = yav(0);
    /* EHDR: EI_CLASS 1 (ELF32), EI_DATA 1 (little), e_type 2 (EXEC),
       e_machine 3 (EM_386), e_version 1. */
    out = kput8(out, 127);
    out = kput8(out, 69);
    out = kput8(out, 76);
    out = kput8(out, 70);
    out = kput8(out, 1);
    out = kput8(out, 1);
    out = kput8(out, 1);
    ylong z = 0;
    while (z < 9) {
        out = kput8(out, 0);
        z++;
    };
    out = kput16(out, 2);
    out = kput16(out, 3);
    out = kput32(out, 1);
    out = kput32(out, entry);
    out = kput32(out, 52);
    out = kput32(out, 0);
    out = kput32(out, 0);
    out = kput16(out, 52);
    out = kput16(out, 32);
    out = kput16(out, 2);
    out = kput16(out, 40);
    out = kput16(out, 0);
    out = kput16(out, 0);
    /* PHDR 1: PT_LOAD, R+X, the whole file, mapped at the base. */
    out = kput32(out, 1);
    out = kput32(out, 0);
    out = kput32(out, base);
    out = kput32(out, base);
    out = kput32(out, filesz);
    out = kput32(out, memsz);
    out = kput32(out, 5);
    out = kput32(out, 4096);
    /* PHDR 2: PT_LOAD, R+W, no file bytes: .bss, zero-filled by the loader. */
    out = kput32(out, 1);
    out = kput32(out, 0);
    out = kput32(out, bss_vaddr);
    out = kput32(out, bss_vaddr);
    out = kput32(out, 0);
    out = kput32(out, kelf_round4k(bss_sz));
    out = kput32(out, 6);
    out = kput32(out, 4096);
    if (yv_len(out) != code_off) {
        puts_(ys_cat(ys_cat(ys_cat(ys_cat(ys("error: kelf: header is "),
                                          ys_long(yv_len(out))),
                                  ys(" bytes, not ")),
                          ys_long(code_off)),
                   ys("\n")));
        exit_(1);
    };
    /* The code and the rodata, then the trailer: the loader supplies the rest
       of the mapping's last page as zeros, as it does for an ELF64 program. */
    ylong i = 0;
    while (i < yv_len(code)) {
        out = ya_push(out, ya_get(code, i));
        i++;
    };
    i = 0;
    while (i < yv_len(rodata)) {
        out = ya_push(out, ya_get(rodata, i));
        i++;
    };
    i = 0;
    while (i < 8) {
        out = ya_push(out, yv_long(0));
        i++;
    };
    return out;
}
