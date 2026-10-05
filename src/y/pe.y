// pe.y — minimal Windows PE32+ writer for `ycc --target=windows`.
//
// The ELF writer's twin (elf.y), and deliberately the same shape: code and
// rodata in one R+X section, zeroed globals in a R+W section whose
// SizeOfRawData is 0, no interpreter, no import table, no relocation
// section, and every address in the image reached by a RIP-relative
// displacement.
//
// WHY NO .reloc IS NEEDED (this is the load-bearing claim, not a
// convenience): label_addr (asm.y) returns a SEGMENT OFFSET, and every
// fixup the assembler patches is a DIFFERENCE of two such offsets -- rel32,
// rel8, rip32 and imm32diff all subtract the instruction end from a target
// offset, never writing an absolute address.  The image therefore contains
// no word the loader would have to add the load bias to, so it can be
// RELOCS_STRIPPED and carry no .reloc at all.  Two things keep that true:
// enc64.y has no movabs, so a 64-bit absolute address would be silently
// truncated rather than diagnosed, and nothing else may write one either --
// so the fixup kinds are enumerated in asm.y's pe_no_abs, which refuses an
// absolute one by name instead of guessing.
//
// Layout, FileAlignment 0x200 and SectionAlignment 0x1000:
//   [DOS header + stub][PE sig][COFF hdr][optional hdr][section headers]
//   [pad to SizeOfHeaders][.text][.bss (no file bytes)][.pdata][.xdata]
//   [.debug_* and the COFF symbol table under -g]
// .text holds the code, then the rodata, then 8 zero bytes: the same
// trailing pad elf.y writes, so the word-at-a-time string loops can
// over-read past a trailing NUL without leaving the section.  .bss holds no
// file bytes at all -- VirtualSize > SizeOfRawData is how PE says "zero me"
// -- which is elf.y's zero-fill trick at 0x200 granularity.
//
// .pdata and .xdata are NOT optional (ideas/WINDOWS.md settles that): a PE
// without them steps under a DWARF debugger but cannot backtrace.  They are
// real unwind data: one RUNTIME_FUNCTION per function (sorted by begin
// address, which the emitted order already is) and one UNWIND_INFO per
// function.  asm.y pe_unwind builds both -- it is where the prologue lives
// to be read from; see its note for how.
//
// Binary data flows through packed [byte] arrays; the driver writes it
// directly so embedded NUL bytes are preserved.

// A section, as this writer thinks of one before it is 40 bytes.
type PeSecHdr = { name: str, vsz: long, rva: long, rawsz: long, rawptr: long, chars: long };

// ── the numbers, in one place ────────────────────────────────────────────
// ImageBase 0x140000000: the conventional x64 EXE base, and because
// RELOCS_STRIPPED is set the image MUST load exactly here.  Anything that
// cannot have 0x140000000 free fails to load -- the price of not emitting a
// .reloc, and the price every hand-written no-reloc PE pays.
let PE_IMAGE_BASE = 5368709120;      // 0x140000000
let PE_SECT_ALIGN = 4096;           // SectionAlignment
let PE_FILE_ALIGN = 512;            // FileAlignment
let PE_TEXT_RVA = 4096;             // the first section's RVA
let PE_MACHINE = 34404;             // 0x8664 IMAGE_FILE_MACHINE_AMD64
let PE_SUBSYSTEM = 3;               // IMAGE_SUBSYSTEM_WINDOWS_CUI
// IMAGE_FILE_RELOCS_STRIPPED | EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE |
// 32BIT_MACHINE
let PE_CHARS = 291;
// .text CNT_CODE|MEM_EXECUTE|MEM_READ; .bss
// CNT_UNINITIALIZED_DATA|MEM_READ|MEM_WRITE; the rest
// CNT_INITIALIZED_DATA|MEM_READ.
let PE_CH_TEXT = 1610612768;         // 0x60000020
let PE_CH_BSS = 3221225600;          // 0xC0000080
let PE_CH_R = 1073741888;            // 0x40000040
// The main stack: 8 MB reserved, 64 KB committed.  Linux leaves the stack to
// the kernel default (8 MB); a program that spawns a thread asks for its own
// 8 MB mapping (arch/wthreads.s), so the main thread gets the same reserve
// here and a deep recursion has the same room on both targets.
let PE_STACK_RESERVE = 8388608;
let PE_STACK_COMMIT = 65536;

// Round V up to a multiple of A (A a power of two).
def pe_align(v: long, a: long) -> long {
    let r = v % a;
    if (r == 0) { v } else { v + a - r }
};

// The RVA of the .bss section: the first page past .text's virtual size.  A
// .bss label resolves through pe_bss_from_ro, so the plain and the -g build
// cannot each have their own formula for it -- the contract
// elf_bss_from_ro has for the ELF side.
def pe_bss_from_ro(code_len: long, ro_len: long, bss_len: long) -> long {
    pe_align(code_len + ro_len + 8, PE_SECT_ALIGN) - code_len
};

// The address the DWARF line table's offsets hang off: ImageBase + .text.
def pe_text_base() -> long {
    PE_IMAGE_BASE + PE_TEXT_RVA
};

// ── the section table ────────────────────────────────────────────────────
// .text always; .bss with a program that has globals; .pdata/.xdata when the
// assembler found any function (always, in practice); then one section per
// .debug_* under -g.  Built as data first and given its RVA and file offset
// here, so every address is computed once, in one order.
def pe_sections(textlen: long, bss_len: long, pdata: [byte], xdata: [byte], dsecs: [PeSecHdr]) -> [PeSecHdr] {
    let out: [PeSecHdr] = [];
    out += pe_sec(".text", textlen, PE_TEXT_RVA, 0, PE_CH_TEXT);
    if (bss_len > 0) {
        out += pe_sec(".bss", bss_len, 0, 0, PE_CH_BSS);
    };
    if (len(pdata) > 0) {
        out += pe_sec(".pdata", len(pdata), 0, 0, PE_CH_R);
    };
    if (len(xdata) > 0) {
        out += pe_sec(".xdata", len(xdata), 0, 0, PE_CH_R);
    };
    let i = 0;
    while (i < len(dsecs)) { out += dsecs[i]; i = i + 1; };
    pe_place(out)
};

// An unplaced section: rawsz and rawptr are zero until pe_place fills them.
def pe_sec(name: str, vsz: long, rva: long, rawptr: long, chars: long) -> PeSecHdr {
    { name: name, vsz: vsz, rva: rva, rawsz: 0, rawptr: rawptr, chars: chars }
};

// Give every section its RVA and its file offset.  A section with no file
// bytes (the .bss) takes the file position it would have had and contributes
// nothing to it -- that is exactly what SizeOfRawData = 0 means.  .text keeps
// the RVA pe_sections gave it; every other section follows, each on the next
// section-alignment boundary.
def pe_place(secs: [PeSecHdr]) -> [PeSecHdr] {
    let raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    let rva = PE_TEXT_RVA;
    let i = 0;
    while (i < len(secs)) {
        let s = secs[i];
        if (i > 0) { rva = pe_align(rva, PE_SECT_ALIGN); };
        let rs = pe_align(s.vsz, PE_FILE_ALIGN);
        if (s.chars == PE_CH_BSS) {
            secs[i] = { name: s.name, vsz: s.vsz, rva: rva, rawsz: 0, rawptr: raw, chars: s.chars };
        } else {
            secs[i] = { name: s.name, vsz: s.vsz, rva: rva, rawsz: rs, rawptr: raw, chars: s.chars };
            raw = raw + rs;
        };
        rva = rva + s.vsz;
        i = i + 1;
    };
    secs
};

// DOS header (64) + stub pad to 0x80, PE signature (4), COFF header (20),
// optional header (240), one 40-byte section header per section.
def pe_headers_size(secs: [PeSecHdr]) -> long {
    0x80 + 4 + 20 + 240 + 40 * len(secs)
};

// The section named `nm`, or an all-zero record when there is none (a data
// directory entry needs a zero, not a missing section).
def pe_find(secs: [PeSecHdr], nm: str) -> PeSecHdr {
    let i = 0;
    let found = pe_sec("", 0, 0, 0, 0);
    while (i < len(secs)) {
        if (secs[i].name == nm) { found = secs[i]; };
        i = i + 1;
    };
    found
};

// ── the image ────────────────────────────────────────────────────────────
// The section's bytes, when it has any: a section with no file bytes writes
// nothing, and the caller's pad lines the file position up.
def pe_payload(out: [byte], sec: PeSecHdr, data: [byte]) -> [byte] {
    if (sec.rawsz == 0) { out } else { push_bytes(out, data) }
};

def pe_pad(out: [byte], upto: long) -> [byte] {
    push_zeros(out, upto - len(out))
};

def pe_build(code: [byte], rodata: [byte], entry_off: long, bss_len: long, pdata: [byte], xdata: [byte], dsecs: [PeSecHdr], ddata: [[byte]], symtab: [byte]) -> [byte] {
    let codesz = len(code);
    let ro_len = len(rodata);
    let trailer: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    let textlen = codesz + ro_len + len(trailer);
    let secs = pe_sections(textlen, bss_len, pdata, xdata, dsecs);
    let size_headers = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    let size_image = pe_align(pe_text_rva(secs) + textlen, PE_SECT_ALIGN);
    let last = secs[len(secs) - 1];
    if (last.vsz > 0) {
        let tail = pe_align(last.rva + last.vsz, PE_SECT_ALIGN);
        if (tail > size_image) { size_image = tail; };
    };
    let out: [byte] = [];
    out = pe_dos(out);
    out = pe_coff(out, len(secs), symtab, pe_symptr(secs));
    out = pe_optional(out, secs, size_headers, size_image, entry_off);
    let i = 0;
    while (i < len(secs)) {
        out = pe_shdr(out, secs[i]);
        i = i + 1;
    };
    out = pe_pad(out, size_headers);
    // .text: code, rodata, the 8-byte zero trailer.
    let t = secs[0];
    let pd = pe_find(secs, ".pdata");
    let xd = pe_find(secs, ".xdata");
    out = pe_payload(out, t, code);
    out = pe_payload(out, t, rodata);
    out = pe_payload(out, t, trailer);
    out = pe_pad(out, t.rawptr + t.rawsz);
    out = pe_payload(out, pd, pdata);
    out = pe_pad(out, pd.rawptr + pd.rawsz);
    out = pe_payload(out, xd, xdata);
    out = pe_pad(out, xd.rawptr + xd.rawsz);
    i = 0;
    while (i < len(dsecs)) {
        let d = dsecs[i];
        let dd = ddata[i];
        out = pe_payload(out, d, dd);
        out = pe_pad(out, d.rawptr + d.rawsz);
        i = i + 1;
    };
    out = push_bytes(out, symtab);
    out
};

// The .text section's RVA, which pe_place may have left alone (it is the one
// section whose RVA is not derived from a predecessor's end).
def pe_text_rva(secs: [PeSecHdr]) -> long {
    pe_find(secs, ".text").rva
};

// Where the COFF symbol table starts: past every section's file bytes.  The
// table and its string table are in the file only -- nothing maps them.
def pe_symptr(secs: [PeSecHdr]) -> long {
    let raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    let i = 0;
    while (i < len(secs)) {
        raw = raw + secs[i].rawsz;
        i = i + 1;
    };
    raw
};

// ── headers ──────────────────────────────────────────────────────────────
// The 64-byte DOS header, a 16-byte stub, then e_lfanew points at 0x80 where
// the PE signature goes.  A real-mode stub is not needed (nothing loads a PE
// that way) but the MZ header and a plausible e_lfanew are, and 0x80 keeps
// the signature 8-byte aligned.
def pe_dos(out: [byte]) -> [byte] {
    let hdr: [byte] = [
        77, 90, 144, 0, 3, 0, 0, 0, 4, 0, 0, 0, 255, 255, 0, 0,
        184, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0
    ];
    out = push_bytes(out, hdr);
    let stub: [byte] = [
        14, 31, 186, 14, 0, 180, 9, 205, 33, 184, 1, 76, 205, 33,
        0, 0
    ];
    out = push_bytes(out, stub);
    pe_pad(out, 0x80)
};

def pe_coff(out: [byte], nsec: long, symtab: [byte], symptr: long) -> [byte] {
    out = push_le32(out, 0x4550);       // "PE\0\0", at e_lfanew
    out = push_le16(out, PE_MACHINE);
    out = push_le16(out, nsec);
    // TimeDateStamp 0: the bytes must be a function of the source alone, so
    // two builds of the same program are identical.
    out = push_le32(out, 0);
    if (len(symtab) > 0) {
        out = push_le32(out, symptr);
        out = push_le32(out, len(symtab) / 18);
    } else {
        out = push_le32(out, 0);
        out = push_le32(out, 0);
    };
    out = push_le16(out, 240);          // SizeOfOptionalHeader (PE32+)
    push_le16(out, PE_CHARS)
};

// The PE32+ optional header: the fixed fields, then 16 data directories of
// which exactly one is used (Exception -> .pdata).  An image with no import
// table and no .reloc needs no other directory.
def pe_optional(out: [byte], secs: [PeSecHdr], size_headers: long, size_image: long, entry_off: long) -> [byte] {
    let size_code = secs[0].rawsz;
    let size_init = 0;
    let i = 0;
    while (i < len(secs)) {
        let s = secs[i];
        if (s.chars != PE_CH_TEXT && s.chars != PE_CH_BSS) { size_init = size_init + s.rawsz; };
        i = i + 1;
    };
    out = push_le16(out, 0x20B);        // Magic: PE32+
    out = push_le16(out, 0);            // linker version 0.0, for the bytes
    out = push_le32(out, size_code);
    out = push_le32(out, size_init);
    // SizeOfUninitializedData: 0.  The .bss is zero-filled by the loader,
    // which is what SizeOfRawData = 0 says; this field only sizes what the
    // linker would have emitted, and nothing here does.
    out = push_le32(out, 0);
    out = push_le32(out, pe_text_rva(secs) + entry_off);
    out = push_le32(out, pe_text_rva(secs));
    out = push_le64(out, PE_IMAGE_BASE);
    out = push_le32(out, PE_SECT_ALIGN);
    out = push_le32(out, PE_FILE_ALIGN);
    out = push_le16(out, 6);            // MajorOperatingSystemVersion
    out = push_le16(out, 0);            // MinorOperatingSystemVersion
    out = push_le16(out, 0);            // MajorImageVersion
    out = push_le16(out, 0);            // MinorImageVersion
    out = push_le16(out, 6);            // MajorSubsystemVersion
    out = push_le16(out, 0);            // MinorSubsystemVersion
    out = push_le32(out, 0);            // Win32VersionValue
    out = push_le32(out, size_image);
    out = push_le32(out, size_headers);
    out = push_le32(out, 0);            // CheckSum: 0 for an EXE
    out = push_le16(out, PE_SUBSYSTEM);
    // DllCharacteristics 0: no NX_COMPAT opt-in and no DYNAMIC_BASE, because
    // there is no .reloc for the latter to act on.
    out = push_le16(out, 0);
    out = push_le64(out, PE_STACK_RESERVE);
    out = push_le64(out, PE_STACK_COMMIT);
    out = push_le64(out, 1048576);      // SizeOfHeapReserve
    out = push_le64(out, 4096);         // SizeOfHeapCommit
    out = push_le32(out, 0);            // LoaderFlags
    out = push_le32(out, 16);           // NumberOfRvaAndSizes
    let pd = pe_find(secs, ".pdata");
    let zero8: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    out = push_bytes(out, zero8);       // 0: Export
    out = push_bytes(out, zero8);       // 1: Import -- none, no library at all
    out = push_bytes(out, zero8);       // 2: Resource
    out = push_le32(out, pd.rva);       // 3: Exception -- .pdata.  A loader
    out = push_le32(out, pd.vsz);       //   that cannot read this refuses the
    out = push_bytes(out, zero8);       // 4: Certificate   image, so it is
    out = push_bytes(out, zero8);       // 5: BaseRelocation not optional
    i = 6;
    while (i < 16) {
        out = push_bytes(out, zero8);
        i = i + 1;
    };
    out
};

// One 40-byte section header.  The name is padded to 8 bytes with NULs: a
// name of 8 or more bytes needs the "/N" string-table form, and no section
// here is that long.
def pe_shdr(out: [byte], s: PeSecHdr) -> [byte] {
    let nm = s.name;
    let i = 0;
    while (i < 8) {
        if (i < len(nm)) { out += byte_at(nm, i); } else { out += 0; };
        i = i + 1;
    };
    out = push_le32(out, s.vsz);
    out = push_le32(out, s.rva);
    out = push_le32(out, s.rawsz);
    out = push_le32(out, s.rawptr);
    out = push_le32(out, 0);            // PointerToRelocations
    out = push_le32(out, 0);            // PointerToLinenumbers
    out = push_le16(out, 0);            // NumberOfRelocations
    out = push_le16(out, 0);            // NumberOfLinenumbers
    push_le32(out, s.chars)
};

export { pe_build, pe_bss_from_ro, pe_text_base, pe_align, pe_sec, pe_place, pe_find, pe_headers_size, PeSecHdr };