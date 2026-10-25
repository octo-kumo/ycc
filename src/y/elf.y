// elf.y — minimal ELF64 writer for ycc output.

import elfenc from "./enc64.y";

// A symbol for -g's .symtab (push_sym), and a section appended past the
// loaded image (elf_debug; dwarf.y makes the .debug_* ones).
type ElfSym = { name: str, sec: long, off: long, size: long };
type ElfSec = { name: str, data: [byte] };

// Accommodate both 4 KiB and 64 KiB Linux AArch64 kernels.
def elf_page() -> long { if (target_is_aarch64()) { 65536 } else { 4096 } };

// File offset of the code: EHDR plus one PHDR, or two with a .bss. A sealed
// image starts its code on a page boundary, so the stub's labels and the
// encrypted range are page-aligned in memory as well as in the section.
def elf_code_off(bss_len: long, sealed: bool = false) -> long {
    if (sealed) { elf_page() }
    else if (bss_len > 0) { 176 } else { 120 }
};

// The R+E image's size in MEMORY, from the code's start: the code, the
// rodata and its 8-byte trailer, rounded up to a page. The tail past the last
// byte in the file is the loader's zero-fill (see the header).
def elf_mem_code(codesz: long, ro_len: long) -> long {
    let page = elf_page();
    let n = codesz + ro_len + 8;
    let trail = n % page;
    if (trail != 0) { n + page - trail } else { n }
};

// The same rounding for a file size that includes the headers (p_memsz).
def elf_memsz(filesz: long) -> long {
    let page = elf_page();
    let trail = filesz % page;
    if (trail != 0) { filesz + page - trail } else { filesz }
};

def elf_bss_from_ro(code_len: long, ro_len: long) -> long {
    elf_mem_code(code_len, ro_len) + elf_page() - code_len
};

def elf_build(code: [byte], rodata: [byte], entry_off: long, bss_len: long, syms: [ElfSym], dsecs: [ElfSec],
        sealed: bool = false) -> [byte] {
    let code_off = elf_code_off(bss_len, sealed);
    let base = 4194304;
    let out: [byte] = [];
    let codesz = len(code);
    let ro_len = len(rodata);
    // What the file holds and what the loader maps. The difference is the
    // last page's zero-fill (elf_mem_code), and it is what the kernel used to
    // be handed as 7,727 literal zero bytes.
    let filesz = code_off + codesz + ro_len + 8;
    let memsz = if (target_is_aarch64()) { filesz } else { elf_memsz(filesz) };
    let bss_vaddr = base + elf_mem_code(codesz, ro_len) + elf_page();
    let entry = base + code_off + entry_off;
    // the .bss address is computed once, here, and handed down: the plain and
    // the -g build must not each have their own formula for it.
    let dbg = elf_debug(code_off, codesz, ro_len, filesz, bss_vaddr, bss_len, syms, dsecs);
    // EHDR
    let header: [byte] = [127, 69, 76, 70, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    out = push_bytes(out, header);
    out = push_le16(out, 2);
    out = push_le16(out, if (target_is_aarch64()) { 183 } else { 62 });
    out = push_le32(out, 1);
    out = push_le64(out, entry);
    out = push_le64(out, 64);
    out = push_le64(out, dbg.shoff);
    out = push_le32(out, 0);
    out = push_le16(out, 64);
    out = push_le16(out, 56);
    let phnum = 1;
    if (bss_len > 0) { phnum = 2; }
    out = push_le16(out, phnum);
    out = dbg.shnum > 0 ? push_le16(out, 64) : push_le16(out, 0);
    out = push_le16(out, dbg.shnum);
    out = push_le16(out, dbg.shstrndx);
    // PHDR: PT_LOAD, R+E
    out = push_le32(out, 1);
    out = push_le32(out, 5);
    out = push_le64(out, 0);
    out = push_le64(out, base);
    out = push_le64(out, base);
    out = push_le64(out, filesz);   // p_filesz: the bytes this file holds
    out = push_le64(out, memsz);    // p_memsz: what is mapped, zero-filled
    out = push_le64(out, elf_page());
    if (bss_len > 0) {
        out = push_le32(out, 1);
        out = push_le32(out, 6);
        out = push_le64(out, dbg.bss_foff);
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, bss_vaddr);
        out = push_le64(out, dbg.bss_fsz);
        out = push_le64(out, code_off + bss_len);
        out = push_le64(out, elf_page());
    }
    if (len(out) < code_off) { out = push_zeros(out, code_off - len(out)); };
    out = push_bytes(out, code);
    out = push_bytes(out, rodata);
    let trailer: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    out = push_bytes(out, trailer);
    out += dbg.bytes;
    out
};

def elf_debug(code_off: long, codesz: long, ro_len: long, filesz: long, bss_vaddr: long, bss_len: long, syms: [ElfSym], dsecs: [ElfSec]) -> { bytes: [byte], shoff: long, shnum: long, shstrndx: long, bss_foff: long, bss_fsz: long } {
    if (len(syms) == 0) {
        let none_b: [byte] = [];
        { bytes: none_b, shoff: 0, shnum: 0, shstrndx: 0, bss_foff: 0, bss_fsz: 0 }
    } else {
        let base = 4194304;
        let ro_off = code_off + codesz;
        // where the labels put the .bss (see the R+W PHDR in elf_build):
        // bss_vaddr already holds the base, and adding it again put every -g
        // .bss symbol 4 MiB away from its object
        let bss_addr = bss_vaddr + code_off;
        let bss_idx = 0;
        let symtab_idx = 3;
        if (bss_len > 0) {
            bss_idx = 3;
            symtab_idx = 4;
        };
        let strtab: [byte] = [0];
        let symtab: [byte] = [];
        symtab = push_zeros(symtab, 24);
        let nlocal = 1;
        foreach (sy in syms) {
            if (sy.name != "_start") {
                symtab = push_sym(symtab, len(strtab), sy, bss_idx, base + code_off, bss_addr, 0);
                strtab = push_cstr(strtab, sy.name);
                nlocal++;
            };
        };
        foreach (sy in syms) {
            if (sy.name == "_start") {
                symtab = push_sym(symtab, len(strtab), sy, bss_idx, base + code_off, bss_addr, 1);
                strtab = push_cstr(strtab, sy.name);
            };
        };
        // section names, each at its offset in .shstrtab
        let shstr: [byte] = [0];
        let n_text = len(shstr);
        shstr = push_cstr(shstr, ".text");
        let n_ro = len(shstr);
        shstr = push_cstr(shstr, ".rodata");
        let n_bss = len(shstr);
        if (bss_len > 0) {
            shstr = push_cstr(shstr, ".bss");
        };
        let n_sym = len(shstr);
        shstr = push_cstr(shstr, ".symtab");
        let n_str = len(shstr);
        shstr = push_cstr(shstr, ".strtab");
        let n_shs = len(shstr);
        shstr = push_cstr(shstr, ".shstrtab");
        let dnames: [long] = [];
        foreach (ds in dsecs) {
            dnames += len(shstr);
            shstr = push_cstr(shstr, ds.name);
        };
        let blob: [byte] = [];
        let bss_foff = 0;
        let bss_fsz = 0;
        let symtab_off = filesz;
        if (bss_len > 0) {
            bss_foff = elf_memsz(filesz);
            bss_fsz = 8;
            if (bss_len < 8) { bss_fsz = bss_len; };
            blob = push_zeros(blob, bss_foff + bss_fsz - filesz);
            symtab_off = bss_foff + bss_fsz;
        };
        let strtab_off = symtab_off + len(symtab);
        let shstr_off = strtab_off + len(strtab);
        blob += symtab;
        blob += strtab;
        blob += shstr;
        let doffs: [long] = [];
        foreach (ds in dsecs) {
            doffs += filesz + len(blob);
            blob += ds.data;
        };
        blob = push_zeros(blob, ((8 - len(blob) % 8) % 8));
        let shoff = filesz + len(blob);
        // section headers
        blob = push_zeros(blob, 64);
        blob = push_shdr(blob, n_text, 1, 6, base + code_off, code_off, codesz, 0, 0, 1, 0);
        blob = push_shdr(blob, n_ro, 1, 2, base + ro_off, ro_off, ro_len, 0, 0, 1, 0);
        if (bss_len > 0) {
            blob = push_shdr(blob, n_bss, 8, 3, bss_addr, bss_foff, bss_len, 0, 0, 8, 0);
        };
        blob = push_shdr(blob, n_sym, 2, 0, 0, symtab_off, len(symtab), symtab_idx + 1, nlocal, 8, 24);
        blob = push_shdr(blob, n_str, 3, 0, 0, strtab_off, len(strtab), 0, 0, 1, 0);
        blob = push_shdr(blob, n_shs, 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0);
        dsecs.foreach((ds, di) => {
            blob = push_shdr(blob, dnames[di], 1, 0, 0, doffs[di], len(ds.data), 0, 0, 1, 0);
        });
        { bytes: blob, shoff: shoff, shnum: symtab_idx + 3 + len(dsecs), shstrndx: symtab_idx + 2, bss_foff: bss_foff, bss_fsz: bss_fsz }
    }
};

// One Elf64_Sym: name offset, info (bind << 4 | type), other, section
// index, value (the address), size.
def push_sym(out: [byte], name_off: long, sy: ElfSym, bss_idx: long, text_addr: long, bss_addr: long, bind: long) -> [byte] {
    out = push_le32(out, name_off);
    if (sy.sec == 0) {
        out += elfenc.byte_of(bind * 16 + 2, 0);
        out += 0;
        out = push_le16(out, 1);
        out = push_le64(out, text_addr + sy.off);
    } else {
        out += elfenc.byte_of(bind * 16 + 1, 0);
        out += 0;
        out = push_le16(out, bss_idx);
        out = push_le64(out, bss_addr + sy.off);
    };
    out = push_le64(out, sy.size);
    out
};

// One Elf64_Shdr.
def push_shdr(out: [byte], name: long, typ: long, flags: long, addr: long, off: long, size: long, link: long, info: long, align: long, entsize: long) -> [byte] {
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
    out
};

// A string's bytes plus its NUL terminator.
def push_cstr(out: [byte], s: str) -> [byte] {
    out += bytes(s);
    out += 0;
    out
};

def push_zeros(out: [byte], n: long) -> [byte] {
    for i in 0..n {
        out += 0;
    };
    out
};

def push_bytes(out: [byte], bytes: [byte]) -> [byte] {
    // NOTE: annotated `[byte]`, not a bare hole: a hole takes its element
    // type from the call site, and these buffers are always packed bytes.
    bytes.foreach((e) => {
        out += e;
    });
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

export { elf_build, elf_code_off, elf_bss_from_ro };
