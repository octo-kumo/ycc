// elf.y — minimal ELF64 writer for ycc output.
// One PT_LOAD segment (read+execute), static, no interpreter, no libc:
// the entry point is our own `_start`, and user code only uses raw syscalls.
// Layout: [EHDR 64][PHDR 56][code][rodata]; base vaddr 0x400000.
//
// Binary data flows through packed [byte] arrays; the driver writes it
// directly so embedded NUL bytes are preserved.

import elfenc from "./enc64.y";

def elf_build(code: [byte], rodata: [byte], entry_off: long) -> [byte] {
    let code_off = 120;
    let base = 4194304;
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
    let out: [byte] = [];
    let codesz = len(code);
    let codetrail = codesz % 4096;
    let codepad = 0;
    if (codetrail != 0) { codepad = 4096 - codetrail; }
    let rosz = len(rodata) + 8;
    let rotrail = rosz % 4096;
    let ropad = 0;
    if (rotrail != 0) { ropad = 4096 - rotrail; }
    let total = code_off + codesz + codepad + rosz + ropad;
    let entry = base + code_off + entry_off;
    // EHDR
    let header: [byte] = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
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
    out = push_le16(out, 1);
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
    out = push_bytes(out, code);
    let p = 0;
    while (p < codepad) {
        out += 0;
        p = p + 1;
    };
    out = push_bytes(out, rodata);
    let trailer: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    out = push_bytes(out, trailer);
    let q = 0;
    while (q < ropad) {
        out += 0;
        q = q + 1;
    };
    out
};

// Append helpers: one in-place append per byte, O(1) amortized. The C twin
// grows the same way (ya_push / ya_grow in src/c/yv.c: 0 -> 8 -> doubling),
// so both copies build the same buffer; each helper returns the array so the
// caller can rebind it.
def push_bytes(out: [byte], bytes: [byte]) -> [byte] {
    // NOTE: annotated `[byte]`, not a bare hole: a hole takes its element
    // type from the call site, and these buffers are always packed bytes.
    let i = 0;
    while (i < len(bytes)) {
        out += bytes[i];
        i = i + 1;
    };
    out
};

def push_le16(out: [byte], v: long) -> [byte] {
    out += elfenc.byte_of(v, 0);
    out += elfenc.byte_of(v, 1);
    out
};

def push_le32(out: [byte], v: long) -> [byte] {
    out += elfenc.byte_of(v, 0);
    out += elfenc.byte_of(v, 1);
    out += elfenc.byte_of(v, 2);
    out += elfenc.byte_of(v, 3);
    out
};

def push_le64(out: [byte], v: long) -> [byte] {
    out += elfenc.byte_of(v, 0);
    out += elfenc.byte_of(v, 1);
    out += elfenc.byte_of(v, 2);
    out += elfenc.byte_of(v, 3);
    out += elfenc.byte_of(v, 4);
    out += elfenc.byte_of(v, 5);
    out += elfenc.byte_of(v, 6);
    out += elfenc.byte_of(v, 7);
    out
};

export { elf_build };
