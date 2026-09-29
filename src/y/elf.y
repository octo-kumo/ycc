// elf.y — minimal ELF64 writer for ycc output.
// One PT_LOAD segment (read+execute), static, no interpreter, no libc:
// the entry point is our own `_start`, and user code only uses raw syscalls.
// Layout: [EHDR 64][PHDR 56][code][rodata]; base vaddr 0x400000.
//
// Bytes are plain longs (0-255) in Y lists; the driver renders them as
// octal escapes for printf (Y strings cannot carry NUL through write_file).

import elfenc from "./enc64.y";

def elf_build(code: [long], rodata: [long], entry_off: long) -> [long] {
    let code_off = 120;
    let base = 4194304;
    // Pad the code to a page so rodata starts page-aligned; pad rodata tail
    // to a page so the mapping covers every string byte (the kernel maps
    // whole pages, and string helpers may over-read a few bytes past a
    // trailing NUL). Layout: [EHDR 64][PHDR 56][code][pad][rodata][pad].
    // Without full-page coverage, argv/envp-adjacent stack reads and even
    // plain rodata loads fault with EFAULT/silent garbage.
    // NOTE: out is built with ONE push per byte (not enc.concat per field):
    // concat copies the whole prefix each time (O(n^2) clones), which hangs
    // the C VM on real (~8K+) inputs. Helpers below append in place.
    let out = [];
    let codesz = len(code);
    let codetrail = codesz % 4096;
    let codepad = 0;
    // NOTE: `0;` tails (see parser.y parse_binary note).
    if (codetrail != 0) { codepad = 4096 - codetrail; 0; } else { 0 };
    let rosz = len(rodata) + 8;
    let rotrail = rosz % 4096;
    let ropad = 0;
    if (rotrail != 0) { ropad = 4096 - rotrail; 0; } else { 0 };
    let total = code_off + codesz + codepad + rosz + ropad;
    let entry = base + code_off + entry_off;
    // EHDR
    out = push_bytes(out, [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
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
        out = push(out, 0);
        p = p + 1;
        0
    };
    out = push_bytes(out, rodata);
    out = push_bytes(out, [0, 0, 0, 0, 0, 0, 0, 0]);
    let q = 0;
    while (q < ropad) {
        out = push(out, 0);
        q = q + 1;
        0
    };
    out
};

// Append helpers: one push per byte (O(1) amortized each). The C VM's push
// clones the array per call, but that is still O(n) per byte appended —
// linear overall, unlike enc.concat(out, field) which re-clones the whole
// prefix for every header field (quadratic, hangs on real inputs).
def push_bytes(out: [long], bytes: [long]) -> [long] {
    // NOTE: annotated [long] (not holes): push() needs known heap arrays.
    let i = 0;
    while (i < len(bytes)) {
        out = push(out, bytes[i]);
        i = i + 1;
        0
    };
    out
};

def push_le16(out: [long], v: long) -> [long] {
    out = push(out, elfenc.byte_of(v, 0));
    out = push(out, elfenc.byte_of(v, 1));
    out
};

def push_le32(out: [long], v: long) -> [long] {
    out = push(out, elfenc.byte_of(v, 0));
    out = push(out, elfenc.byte_of(v, 1));
    out = push(out, elfenc.byte_of(v, 2));
    out = push(out, elfenc.byte_of(v, 3));
    out
};

def push_le64(out: [long], v: long) -> [long] {
    out = push(out, elfenc.byte_of(v, 0));
    out = push(out, elfenc.byte_of(v, 1));
    out = push(out, elfenc.byte_of(v, 2));
    out = push(out, elfenc.byte_of(v, 3));
    out = push(out, elfenc.byte_of(v, 4));
    out = push(out, elfenc.byte_of(v, 5));
    out = push(out, elfenc.byte_of(v, 6));
    out = push(out, elfenc.byte_of(v, 7));
    out
};

export { elf_build };
