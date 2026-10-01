/* elf.c — minimal ELF64 writer for ycc output.
 * 1:1 C copy of src/y/elf.y (see PORTING.md).
 * One PT_LOAD segment (read+execute), static, no interpreter, no libc:
 * the entry point is our own `_start`, and user code only uses raw syscalls.
 * Layout: [EHDR 64][PHDR 56][code][rodata]; base vaddr 0x400000.
 * A program with globals gets a second PT_LOAD (read+write, no file bytes):
 * the zeroed .bss, on the page after the file mapping; its PHDR makes the
 * headers 176 bytes.
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

static long elf_ro_total(long ro_len) {
    long rosz = ro_len + 8;
    long trail = rosz % 4096;
    if (trail != 0) { return rosz + 4096 - trail; } else { return rosz; }
}

long elf_bss_from_ro(long ro_len, long bss_len) {
    return elf_ro_total(ro_len) + 4096 - elf_code_off(bss_len);
}

Yv *elf_build(Yv *code, Yv *rodata, long entry_off, long bss_len) {
    long code_off = elf_code_off(bss_len);
    long base = 4194304;
    // Pad the code to a page so rodata starts page-aligned; pad rodata tail
    // to a page so the mapping covers every string byte (the kernel maps
    // whole pages, and string helpers may over-read a few bytes past a
    // trailing NUL). Layout: [EHDR 64][PHDR 56][code][pad][rodata][pad].
    // Without full-page coverage the last partial page is the end of the
    // mapping, so those over-reads (and any read of the tail) fault with
    // EFAULT or return garbage.
    // NOTE: out is appended to IN PLACE, one byte at a time, rather than
    // re-concatenated per header field: `+=` grows the array geometrically,
    // while `out = concat(out, f)` would allocate a fresh array and copy
    // every byte written so far, for every field. Helpers below append.
    Yv *out = yav(0);
    long codesz = yv_len(code);
    long codetrail = codesz % 4096;
    long codepad = 0;
    // NOTE: `0;` tails (see parser.y parse_binary note).
    if (codetrail != 0) { codepad = 4096 - codetrail; ; } else { ; }
    long rosz = yv_len(rodata) + 8;
    long rotrail = rosz % 4096;
    long ropad = 0;
    if (rotrail != 0) { ropad = 4096 - rotrail; ; } else { ; }
    long total = code_off + codesz + codepad + rosz + ropad;
    long entry = base + code_off + entry_off;
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
    out = push_le64(out, 0);
    out = push_le32(out, 0);
    out = push_le16(out, 64);
    out = push_le16(out, 56);
    long phnum = 1;
    if (bss_len > 0) { phnum = 2; ; } else { ; };
    out = push_le16(out, phnum);
    out = push_le16(out, 0);
    out = push_le16(out, 0);
    out = push_le16(out, 0);
    // PHDR: PT_LOAD, R+E
    out = push_le32(out, 1);
    out = push_le32(out, 5);
    out = push_le64(out, 0);
    out = push_le64(out, base);
    out = push_le64(out, base);
    out = push_le64(out, total);
    out = push_le64(out, total);
    out = push_le64(out, 4096);
    if (bss_len > 0) {
        /* PHDR: PT_LOAD, R+W, nothing from the file (the kernel maps
         * zeroed pages), on the page after the file mapping. */
        long bss_vaddr = base + total - code_off + 4096;
        out = push_le32(out, 1);
        out = push_le32(out, 6);
        out = push_le64(out, 0);
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, 0);
        out = push_le64(out, bss_len);
        out = push_le64(out, 4096);
        ;
    } else {
        ;
    }
    out = push_bytes(out, code);
    long p = 0;
    while (p < codepad) {
        out = ya_push(out, yv_long(0));
        p = p + 1;
        ;
    }
    out = push_bytes(out, rodata);
    Yv *trailer = yav(8, yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                      yv_long(0), yv_long(0), yv_long(0), yv_long(0));
    out = push_bytes(out, trailer);
    long q = 0;
    while (q < ropad) {
        out = ya_push(out, yv_long(0));
        q = q + 1;
        ;
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
