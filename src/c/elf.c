/* elf.c — minimal ELF64 writer for ycc output.
 * 1:1 C copy of src/y/elf.y (see PORTING.md).
 * One PT_LOAD segment (read+execute), static, no interpreter, no libc:
 * the entry point is our own `_start`, and user code only uses raw syscalls.
 * Layout: [EHDR 64][PHDR 56][code][rodata]; base vaddr 0x400000. Nothing is
 * padded in the file: the R+E segment's p_memsz is rounded up to a page while
 * its p_filesz is the bytes actually written, and ELF already says what the
 * tail holds — the loader zero-fills it. That tail is not slack (the kernel
 * maps whole pages and string helpers over-read a few bytes past a trailing
 * NUL), so it has to be mapped and zeroed, which is what p_memsz > p_filesz
 * buys. A hello-world binary is 585 bytes instead of 8,312, of which 7,727
 * were zeros the loader threw away and rebuilt anyway.
 * A program with globals gets a second PT_LOAD (read+write, no file bytes):
 * the zeroed .bss, on the page after the mapped image; its PHDR makes the
 * headers 176 bytes.
 * `ycc -g` appends [.symtab][.strtab][.shstrtab][.debug_*][section
 * headers] AFTER the loaded image (see elf_debug), and backs the first
 * bytes of the .bss with zeros from the file (for valgrind): the code,
 * rodata and every address stay the same, so the program runs the same
 * bytes either way.
 *
 * Y-side binary data flows through packed [byte] arrays. The C value model
 * keeps each element as a boxed long; the driver writes it directly. */

#include "elf.h"

/* imported — src/y/enc64.y (`import elfenc from "./enc64.y";`; module calls
 * are flattened, `elfenc.byte_of(v, i)` -> `byte_of(v, i)`). enc64.h now
 * exists, so the prototype comes from there; it matches enc64.y:
 * `def byte_of(v: long, i: long) -> long`. */
#include "enc64.h"

long elf_code_off(long bss_len) {
    if (bss_len > 0) { return 176; } else { return 120; }
}

/* The R+E image's size in MEMORY, from the code's start: the code, the
   rodata and its 8-byte trailer, rounded up to a page. The tail past the last
   byte in the file is the loader's zero-fill (see the header). */
static long elf_mem_code(long codesz, long ro_len) {
    long n = codesz + ro_len + 8;
    long trail = n % 4096;
    if (trail != 0) { return n + 4096 - trail; } else { return n; }
}

/* The same rounding for a file size that includes the headers (p_memsz). */
static long elf_memsz(long filesz) {
    long trail = filesz % 4096;
    if (trail != 0) { return filesz + 4096 - trail; } else { return filesz; }
}

long elf_bss_from_ro(long code_len, long ro_len, long bss_len) {
    return elf_mem_code(code_len, ro_len) + 4096 - code_len;
}

Yv *elf_build(Yv *code, Yv *rodata, long entry_off, long bss_len,
              Yv *syms, Yv *dsecs) {
    long code_off = elf_code_off(bss_len);
    long base = 4194304;
    // Layout: [EHDR 64][PHDR 56][code][rodata + trailer]. Nothing is padded:
    // rodata need not be page-aligned (it is reached through a patched
    // rip-relative lea), and the mapping's last page is zero-filled by the
    // loader rather than by bytes in the file.
    // NOTE: out is appended to IN PLACE, one byte at a time, rather than
    // re-concatenated per header field: `+=` grows the array geometrically,
    // while `out = concat(out, f)` would allocate a fresh array and copy
    // every byte written so far, for every field. Helpers below append.
    Yv *out = yav(0);
    long codesz = yv_len(code);
    long ro_len = yv_len(rodata);
    /* What the file holds and what the loader maps. The difference is the
       last page's zero-fill (elf_mem_code), and it is what the kernel used to
       be handed as 7,727 literal zero bytes. */
    long filesz = code_off + codesz + ro_len + 8;
    long memsz = elf_memsz(filesz);
    long bss_vaddr = base + elf_mem_code(codesz, ro_len) + 4096;
    long entry = base + code_off + entry_off;
    /* the .bss address is computed once, here, and handed down: the plain and
       the -g build must not each have their own formula for it. */
    Yv *dbg = elf_debug(code_off, codesz, ro_len, filesz, bss_vaddr,
                        bss_len, syms, dsecs);
    // EHDR
    Yv *header = yav(16, yv_long(127), yv_long(69), yv_long(76),
                     yv_long(70), yv_long(2), yv_long(1), yv_long(1),
                     yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                     yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                     yv_long(0));
    out = push_bytes(out, header);
    out = push_le16(out, 2);
    out = push_le16(out, 62);
    out = push_le32(out, 1);
    out = push_le64(out, entry);
    out = push_le64(out, 64);
    out = push_le64(out, yv_l(yr_get(dbg, "shoff")));
    out = push_le32(out, 0);
    out = push_le16(out, 64);
    out = push_le16(out, 56);
    long phnum = 1;
    if (bss_len > 0) { phnum = 2; ; }
    out = push_le16(out, phnum);
    if (yv_l(yr_get(dbg, "shnum")) > 0) {
        out = push_le16(out, 64);
    } else {
        out = push_le16(out, 0);
    }
    out = push_le16(out, yv_l(yr_get(dbg, "shnum")));
    out = push_le16(out, yv_l(yr_get(dbg, "shstrndx")));
    // PHDR: PT_LOAD, R+E
    out = push_le32(out, 1);
    out = push_le32(out, 5);
    out = push_le64(out, 0);
    out = push_le64(out, base);
    out = push_le64(out, base);
    out = push_le64(out, filesz);   /* p_filesz: the bytes this file holds */
    out = push_le64(out, memsz);    /* p_memsz: what is mapped, zero-filled */
    out = push_le64(out, 4096);
    if (bss_len > 0) {
        /* PHDR: PT_LOAD, R+W, nothing from the file (the kernel maps
         * zeroed pages; -g: a few zero bytes, see elf_debug), on the page
         * after the mapped image. */
        out = push_le32(out, 1);
        out = push_le32(out, 6);
        out = push_le64(out, yv_l(yr_get(dbg, "bss_foff")));
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, yv_l(yr_get(dbg, "bss_fsz")));
        out = push_le64(out, bss_len);
        out = push_le64(out, 4096);
        ;
    }
    out = push_bytes(out, code);
    out = push_bytes(out, rodata);
    Yv *trailer = yav(8, yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                      yv_long(0), yv_long(0), yv_long(0), yv_long(0));
    out = push_bytes(out, trailer);
    out = push_bytes(out, yr_get(dbg, "bytes"));
    return out;
}

/* -g: the symbol table and section headers, as the bytes that follow the
 * loaded image: [.bss head][.symtab][.strtab][.shstrtab][dsecs][pad to 8]
 * [section headers]. Sections: 0 null, 1 .text, 2 .rodata, 3 .bss (only
 * with a .bss), then .symtab, .strtab, .shstrtab, then dsecs (dwarf.y's
 * .debug_* sections: no address, no flags) in order. Symbols are local
 * (STB_LOCAL, listed first, as ELF requires) except `_start`, the one
 * global; text symbols are STT_FUNC, .bss ones STT_OBJECT. No symbols:
 * no bytes, no headers — the plain build is unchanged.
 * The .bss head: valgrind reads an executable's symbols only once it has
 * seen a file-backed read+write mapping of it, so a -g build takes the
 * first bytes of the .bss from zeros in the file (bss_foff/bss_fsz, the
 * R+W PHDR's p_offset/p_filesz), at the page boundary past the image
 * (p_offset must share p_vaddr's page offset). The loader zeroes the rest
 * of that page, so memory holds the same zeros as without -g. */
Yv *elf_debug(long code_off, long codesz, long ro_len, long filesz,
              long bss_vaddr, long bss_len, Yv *syms, Yv *dsecs) {
    if (yv_len(syms) == 0) {
        Yv *none_bytes = yav(0);
        return yr(6, "bytes", none_bytes, "shoff", yv_long(0), "shnum",
                  yv_long(0), "shstrndx", yv_long(0), "bss_foff",
                  yv_long(0), "bss_fsz", yv_long(0));
    } else {
        long base = 4194304;
        long ro_off = code_off + codesz;
        long bss_addr = base + bss_vaddr;
        long bss_idx = 0;
        long symtab_idx = 3;
        if (bss_len > 0) {
            bss_idx = 3;
            symtab_idx = 4;
        }
        Yv *strtab = yav(1, yv_long(0));
        Yv *symtab = yav(0);
        symtab = push_zeros(symtab, 24);
        long nlocal = 1;
        long i = 0;
        while (i < yv_len(syms)) {
            Yv *sy = ya_get(syms, i);
            if (!ys_eq_lit(yr_get(sy, "name"), "_start")) {
                symtab = push_sym(symtab, yv_len(strtab), sy, bss_idx,
                                  base + code_off, bss_addr, 0);
                strtab = push_cstr(strtab, yr_get(sy, "name"));
                nlocal = nlocal + 1;
            }
            i = i + 1;
        }
        i = 0;
        while (i < yv_len(syms)) {
            Yv *sy = ya_get(syms, i);
            if (ys_eq_lit(yr_get(sy, "name"), "_start")) {
                symtab = push_sym(symtab, yv_len(strtab), sy, bss_idx,
                                  base + code_off, bss_addr, 1);
                strtab = push_cstr(strtab, yr_get(sy, "name"));
            }
            i = i + 1;
        }
        /* section names, each at its offset in .shstrtab */
        Yv *shstr = yav(1, yv_long(0));
        long n_text = yv_len(shstr);
        shstr = push_cstr(shstr, ys(".text"));
        long n_ro = yv_len(shstr);
        shstr = push_cstr(shstr, ys(".rodata"));
        long n_bss = yv_len(shstr);
        if (bss_len > 0) {
            shstr = push_cstr(shstr, ys(".bss"));
        }
        long n_sym = yv_len(shstr);
        shstr = push_cstr(shstr, ys(".symtab"));
        long n_str = yv_len(shstr);
        shstr = push_cstr(shstr, ys(".strtab"));
        long n_shs = yv_len(shstr);
        shstr = push_cstr(shstr, ys(".shstrtab"));
        Yv *dnames = yav(0);
        long di = 0;
        while (di < yv_len(dsecs)) {
            Yv *ds = ya_get(dsecs, di);
            dnames = ya_push(dnames, yv_long(yv_len(shstr)));
            shstr = push_cstr(shstr, yr_get(ds, "name"));
            di = di + 1;
        }
        Yv *blob = yav(0);
        long bss_foff = 0;
        long bss_fsz = 0;
        long symtab_off = filesz;
        if (bss_len > 0) {
            /* The .bss head must sit at a file offset that shares the mapped
               page offset of its address (the R+W PHDR's p_offset against
               p_vaddr), and that address is on a page boundary, so this
               offset is too — which, now that the image is not padded, means
               up to 4095 zeros between the image and the debug blob. They are
               zeros the loader would have written anyway; the blob cannot
               move into that gap because then it would be mapped, and a
               string over-read would see it instead of the zeros. */
            bss_foff = elf_memsz(filesz);
            bss_fsz = 8;
            if (bss_len < 8) {
                bss_fsz = bss_len;
            }
            blob = push_zeros(blob, bss_foff + bss_fsz - filesz);
            symtab_off = bss_foff + bss_fsz;
        }
        long strtab_off = symtab_off + yv_len(symtab);
        long shstr_off = strtab_off + yv_len(strtab);
        blob = push_bytes(blob, symtab);
        blob = push_bytes(blob, strtab);
        blob = push_bytes(blob, shstr);
        Yv *doffs = yav(0);
        di = 0;
        while (di < yv_len(dsecs)) {
            Yv *ds = ya_get(dsecs, di);
            doffs = ya_push(doffs, yv_long(filesz + yv_len(blob)));
            blob = push_bytes(blob, yr_get(ds, "data"));
            di = di + 1;
        }
        long pad = (8 - yv_len(blob) % 8) % 8;
        blob = push_zeros(blob, pad);
        long shoff = filesz + yv_len(blob);
        /* section headers */
        blob = push_zeros(blob, 64);
        blob = push_shdr(blob, n_text, 1, 6, base + code_off, code_off,
                         codesz, 0, 0, 1, 0);
        blob = push_shdr(blob, n_ro, 1, 2, base + ro_off, ro_off, ro_len, 0,
                         0, 1, 0);
        if (bss_len > 0) {
            blob = push_shdr(blob, n_bss, 8, 3, bss_addr, bss_foff, bss_len,
                             0, 0, 8, 0);
        }
        blob = push_shdr(blob, n_sym, 2, 0, 0, symtab_off,
                         yv_len(symtab), symtab_idx + 1, nlocal, 8, 24);
        blob = push_shdr(blob, n_str, 3, 0, 0, strtab_off, yv_len(strtab), 0,
                         0, 1, 0);
        blob = push_shdr(blob, n_shs, 3, 0, 0, shstr_off, yv_len(shstr), 0,
                         0, 1, 0);
        di = 0;
        while (di < yv_len(dsecs)) {
            Yv *ds = ya_get(dsecs, di);
            Yv *dd = yr_get(ds, "data");
            blob = push_shdr(blob, yv_l(ya_get(dnames, di)), 1, 0, 0,
                             yv_l(ya_get(doffs, di)), yv_len(dd), 0, 0, 1, 0);
            di = di + 1;
        }
        return yr(6, "bytes", blob, "shoff", yv_long(shoff), "shnum",
                  yv_long(symtab_idx + 3 + yv_len(dsecs)), "shstrndx",
                  yv_long(symtab_idx + 2), "bss_foff", yv_long(bss_foff),
                  "bss_fsz", yv_long(bss_fsz));
    }
}

/* One Elf64_Sym: name offset, info (bind << 4 | type), other, section
 * index, value (the address), size. */
Yv *push_sym(Yv *out, long name_off, Yv *sy, long bss_idx, long text_addr,
             long bss_addr, long bind) {
    out = push_le32(out, name_off);
    if (yv_l(yr_get(sy, "sec")) == 0) {
        out = ya_push(out, yv_long(byte_of(bind * 16 + 2, 0)));
        out = ya_push(out, yv_long(0));
        out = push_le16(out, 1);
        out = push_le64(out,
                        text_addr + yv_l(yr_get(sy, "off")));
    } else {
        out = ya_push(out, yv_long(byte_of(bind * 16 + 1, 0)));
        out = ya_push(out, yv_long(0));
        out = push_le16(out, bss_idx);
        out = push_le64(out,
                        bss_addr + yv_l(yr_get(sy, "off")));
    }
    out = push_le64(out, yv_l(yr_get(sy, "size")));
    return out;
}

/* One Elf64_Shdr. */
Yv *push_shdr(Yv *out, long name, long typ, long flags, long addr, long off,
              long size, long link, long info, long align, long entsize) {
    out = push_le32(out, name);
    out = push_le32(out, typ);
    out = push_le64(out, flags);
    out = push_le64(out, addr);
    out = push_le64(out, off);
    out = push_le64(out, size);
    out = push_le32(out, link);
    out = push_le32(out, info);
    out = push_le64(out, align);
    out = push_le64(out, entsize);
    return out;
}

/* A string's bytes plus its NUL terminator. */
Yv *push_cstr(Yv *out, Yv *s) {
    out = push_bytes(out, bytes_of(s));
    out = ya_push(out, yv_long(0));
    return out;
}

Yv *push_zeros(Yv *out, long n) {
    long i = 0;
    while (i < n) {
        out = ya_push(out, yv_long(0));
        i = i + 1;
    }
    return out;
}

// Append helpers: one in-place append per byte, O(1) amortized. The C twin
// grows the same way (ya_push / ya_grow in src/c/yv.c: 0 -> 8 -> doubling),
// so both copies build the same buffer; each helper returns the array so the
// caller can rebind it.
Yv *push_bytes(Yv *out, Yv *bytes) {
    // NOTE: annotated `[byte]`, not a bare hole: a hole takes its element
    // type from the call site, and these buffers are always packed bytes.
    long i = 0;
    while (i < yv_len(bytes)) {
        out = ya_push(out, ya_get(bytes, i));
        i = i + 1;
        ;
    }
    return out;
}

Yv *push_le16(Yv *out, long v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    out = ya_push(out, yv_long(byte_of(v, 1)));
    return out;
}

Yv *push_le32(Yv *out, long v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    out = ya_push(out, yv_long(byte_of(v, 1)));
    out = ya_push(out, yv_long(byte_of(v, 2)));
    out = ya_push(out, yv_long(byte_of(v, 3)));
    return out;
}

Yv *push_le64(Yv *out, long v) {
    out = ya_push(out, yv_long(byte_of(v, 0)));
    out = ya_push(out, yv_long(byte_of(v, 1)));
    out = ya_push(out, yv_long(byte_of(v, 2)));
    out = ya_push(out, yv_long(byte_of(v, 3)));
    out = ya_push(out, yv_long(byte_of(v, 4)));
    out = ya_push(out, yv_long(byte_of(v, 5)));
    out = ya_push(out, yv_long(byte_of(v, 6)));
    out = ya_push(out, yv_long(byte_of(v, 7)));
    return out;
}

/* export { elf_build, elf_code_off, elf_bss_from_ro }; */
