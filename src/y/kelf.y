// kelf.y — the ELF32 Multiboot-1 writer for `ycc --target=kernel`.

import enc from "./enc64.y";

// Where the payload is loaded.  Multiboot says 1 MB, which is also where the
// linker puts it in the experiment, so the two can be diffed byte for byte.
def kelf_base() -> long {
    1048576
};

// The file offset of the code: ELF32 EHDR (52) plus two PHDR (32 each).
// arch_x64.y's trampoline bakes this in (its 32-bit code cannot ask the
// writer where it is), so it is a function here and both read it.
def kelf_code_off() -> long {
    116
};

// The 12-byte Multiboot header precedes `_start`; arch_x64.y's blob builder
// needs the same number to place the trampoline's own label.
def kelf_head_len() -> long {
    12
};

def kelf_round4k(n: long) -> long {
    let trail = n % 4096;
    if (trail != 0) { n + 4096 - trail } else { n }
};

// The load image's size in memory, headers included: the code, the rodata and
// the 8-byte trailer (string helpers over-read past a trailing NUL), rounded
// up to a page.
def kelf_img_memsz(code_len: long, ro_len: long) -> long {
    kelf_round4k(kelf_code_off() + code_len + ro_len + 8)
};

// Where .bss starts, as an offset from the rodata's start -- the same shape
// as elf.y's elf_bss_from_ro, and the one asm_link rebases every .bss label
// by (asm_bss_shift).
def kelf_bss_from_ro(code_len: long, ro_len: long) -> long {
    kelf_img_memsz(code_len, ro_len) - kelf_code_off() - code_len
};

// The bss segment's virtual address: the page after the loaded image.
def kelf_bss_vaddr(code_len: long, ro_len: long) -> long {
    kelf_base() + kelf_img_memsz(code_len, ro_len)
};

// ── little-endian field writers (the file has no libc and no buffer API) ──
def kput16(out: [byte], v: long) -> [byte] {
    out += enc.byte_of(v, 0);
    out += enc.byte_of(v, 1);
    out
};

def kput32(out: [byte], v: long) -> [byte] {
    out += enc.byte_of(v, 0);
    out += enc.byte_of(v, 1);
    out += enc.byte_of(v, 2);
    out += enc.byte_of(v, 3);
    out
};

def kput8(out: [byte], v: long) -> [byte] {
    out += enc.byte_of(v, 0);
    out
};

// ── the image ─────────────────────────────────────────────────────────────
def kelf_build(code: [byte], rodata: [byte], entry_off: long, bss_len: long) -> [byte] {
    let base = kelf_base();
    let code_off = kelf_code_off();
    let codesz = len(code);
    let ro_len = len(rodata);
    let filesz = code_off + codesz + ro_len + 8;
    let memsz = kelf_img_memsz(codesz, ro_len);
    let bss_vaddr = kelf_bss_vaddr(codesz, ro_len);
    let entry = base + code_off + entry_off;
    let bss_sz = bss_len;
    if (bss_sz == 0) { bss_sz = 4096; };
    let out: [byte] = [];
    // EHDR: EI_CLASS 1 (ELF32), EI_DATA 1 (little), e_type 2 (EXEC),
    // e_machine 3 (EM_386), e_version 1.
    out = kput8(out, 127);
    out = kput8(out, 69);
    out = kput8(out, 76);
    out = kput8(out, 70);
    out = kput8(out, 1);
    out = kput8(out, 1);
    out = kput8(out, 1);
    let z = 0;
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
    // PHDR 1: PT_LOAD, R+X, the whole file, mapped at the base.
    out = kput32(out, 1);
    out = kput32(out, 0);
    out = kput32(out, base);
    out = kput32(out, base);
    out = kput32(out, filesz);
    out = kput32(out, memsz);
    out = kput32(out, 5);
    out = kput32(out, 4096);
    // PHDR 2: PT_LOAD, R+W, no file bytes: .bss, zero-filled by the loader.
    out = kput32(out, 1);
    out = kput32(out, 0);
    out = kput32(out, bss_vaddr);
    out = kput32(out, bss_vaddr);
    out = kput32(out, 0);
    out = kput32(out, kelf_round4k(bss_sz));
    out = kput32(out, 6);
    out = kput32(out, 4096);
    if (len(out) != code_off) {
        puts("error: kelf: header is " + tostring(len(out)) + " bytes, not " + tostring(code_off) + "\n");
        exit(1);
    };
    // The code and the rodata, then the trailer: the loader supplies the rest
    // of the mapping's last page as zeros, as it does for an ELF64 program.
    let i = 0;
    while (i < len(code)) {
        out += code[i];
        i++;
    };
    i = 0;
    while (i < len(rodata)) {
        out += rodata[i];
        i++;
    };
    i = 0;
    while (i < 8) {
        out += 0;
        i++;
    };
    out
};

export { kelf_build, kelf_base, kelf_code_off, kelf_head_len, kelf_bss_from_ro, kelf_bss_vaddr, kelf_img_memsz };
