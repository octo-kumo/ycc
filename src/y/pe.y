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
// INITIALIZED_DATA|MEM_READ|MEM_WRITE (0xC0000040): the import section. It has
// file bytes (the ILT, which is what a loader that does not resolve an import
// leaves behind) and the loader WRITES the resolved addresses over the IAT in
// the same pages, so it cannot be read-only.
let PE_CH_RW = 3221225536;
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
    while (i < len(dsecs)) { out += dsecs[i]; i++; };
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
    secs.foreach((_el, i) => {
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
    });
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
        i++;
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

// ── the import table ─────────────────────────────────────────────────────
// One DLL and one function, for now, and it is scaffolding with a purpose:
// Windows has no syscall for randomness (BCryptGenRandom), for sockets
// (Winsock) or for the console API, so the WINDOWS.md items that need those
// come in through PE imports -- and until this existed the writer had none at
// all ("no import table, no relocation section", the header above said). This
// emits a well-formed IMAGE_IMPORT_DESCRIPTOR for KERNEL32.dll's
// GetCurrentProcessId, so the loader's resolution path is exercised end to end
// (objdump -p reads the table, and wine refuses an image whose table is
// malformed) before anything depends on it.
// The imports the image carries, in the order the descriptors appear -- the
// list itself is arch_x64's, because the linker has to reserve a .bss cell for
// every function named in it and that happens long before this writer runs.
// `bcrypt.dll!BCryptGenRandom` is the one std/crypto.y's `y_os_random` needs
// on NT: Windows has no syscall for randomness.
// The import list's type is arch_x64's WImport -- declared there because the
// linker needs it too, and one record type with two names is a warning (a
// record type IS its set of fields, so the alias bought nothing anyway).
def pe_imports() -> [WImport] { arch.w_imports() };

// Four little-endian bytes of `v` at `at`, in place.
def pe_put32(b: [byte], at: long, v: long) -> void {
    b[at] = v % 256;
    b[at + 1] = v / 256 % 256;
    b[at + 2] = v / 65536 % 256;
    b[at + 3] = v / 16777216 % 256;
};

// Eight, the low half first: every value here is an RVA, so the high half is
// zero and the second store is what makes the entry 8 bytes rather than 4.
def pe_put64(b: [byte], at: long, v: long) -> void {
    pe_put32(b, at, v % 4294967296);
    pe_put32(b, at + 4, v / 4294967296);
};

def pe_put_str(b: [byte], at: long, s: str) -> void {
    let i = 0;
    while (i < len(s)) { b[at + i] = s[i]; i++; };
    b[at + len(s)] = 0;
};

// The .idata image. The layout, all offsets from the section's start:
//
//   0   IMAGE_IMPORT_DESCRIPTOR     OriginalFirstThunk -> ILT
//                                   Name               -> the DLL name
//                                   FirstThunk         -> IAT
//   20  a zero descriptor          the terminator
//   40  the ILT                    one 8-byte RVA per function, then 0
//       the IAT                    the same shape; the loader overwrites it
//       hint/name entries          a 2-byte hint then the name, NUL, even
//       the DLL name, NUL
//
// `rva` is the section's own RVA when the bytes are real, and 0 when only the
// LENGTH is wanted -- the size has to be known before placement (the section
// headers depend on it) and the RVAs are not known until after, which is why
// this is called twice. Every pointer is an RVA, which survives wherever the
// image loads; nothing here is a virtual address, which is the property that
// lets the image stay RELOCS_STRIPPED.
// The .idata image for every DLL in `spec`. The layout, all offsets from the
// section's start (nd = number of DLLs, nf[i] = functions of DLL i):
//
//   0            nd+1 IMAGE_IMPORT_DESCRIPTORs, the last all zero
//   d_off        the ILTs, one per DLL: 8 bytes a function, then a zero
//   i_off        the IATs, the same shape; the loader overwrites these
//   h_off        hint/name entries: a 2-byte hint, the name, NUL, even
//   n_off        the DLL names, NUL terminated
//
// `rva` is the section's own RVA when the bytes are real and 0 when only the
// LENGTH is wanted -- the size has to be known before placement (the section
// headers depend on it) and the RVAs are not known until after, which is why
// this is called twice. Every pointer is an RVA, which survives wherever the
// image loads, and that is what lets the image stay RELOCS_STRIPPED.
def pe_import_bytes(spec: [WImport], rva: long, bss_rva: long) -> [byte] {
    let nd = len(spec);
    let descs = 20 * (nd + 1);
    // One ILT and one IAT per DLL, in DLL order.
    let ilt: [long] = [];
    let iat: [long] = [];
    let at = descs;
    let i = 0;
    while (i < nd) {
        ilt += at;
        at = at + 8 * (len(spec[i].funcs) + 1);
        i++;
    };
    i = 0;
    while (i < nd) {
        iat += at;
        at = at + 8 * (len(spec[i].funcs) + 1);
        i++;
    };
    // The hint/name entries, then the DLL names.
    let hoff: [[long]] = [];
    i = 0;
    while (i < nd) {
        let row: [long] = [];
        for k in 0..len(spec[i].funcs) {
            row += at;
            at = at + 2 + len(spec[i].funcs[k]) + 1;
            if (at % 2 != 0) { at = at + 1; };
        };
        hoff += row;
        i++;
    };
    let noff: [long] = [];
    i = 0;
    while (i < nd) {
        noff += at;
        at = at + len(spec[i].dll) + 1;
        i++;
    };
    let total = at;
    let out: [byte] = [];
    let z = 0;
    while (z < total) { out += 0; z++; };
    i = 0;
    while (i < nd) {
        let d = 20 * i;
        pe_put32(out, d, rva + ilt[i]);         // OriginalFirstThunk
        pe_put32(out, d + 12, rva + noff[i]);   // Name
        // FirstThunk is where the loader WRITES the resolved addresses: the
        // .bss cells w_iat_offset names (the block that starts .bss, so the
        // code's `mov y_iat_X(%rip), %rax` and this agree by construction),
        // with a zeroed terminator cell after each DLL's functions.
        pe_put32(out, d + 16, bss_rva + arch.w_iat_offset(i, 0));
        for k in 0..len(spec[i].funcs) {
            pe_put64(out, ilt[i] + 8 * k, rva + hoff[i][k]);
            pe_put64(out, iat[i] + 8 * k, rva + hoff[i][k]);
            pe_put_str(out, hoff[i][k] + 2, spec[i].funcs[k]);
        };
        pe_put_str(out, noff[i], spec[i].dll);
        i++;
    };
    out
};

def pe_build(code: [byte], rodata: [byte], entry_off: long, bss_len: long, pdata: [byte], xdata: [byte], dsecs: [PeSecHdr], ddata: [[byte]], symtab: [byte], imp: [WImport]) -> [byte] {
    let codesz = len(code);
    let ro_len = len(rodata);
    let trailer: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    let textlen = codesz + ro_len + len(trailer);
    // The import section is placed with the rest, sized before its bytes can
    // be built (an RVA is only known after pe_place) and rebuilt after it.
    let dsecs2: [PeSecHdr] = [];
    let ddata2: [[byte]] = [];
    let di = 0;
    while (di < len(dsecs)) { dsecs2 += dsecs[di]; ddata2 += ddata[di]; di++; };
    let imp_sz = 0;
    if (len(imp) > 0) {
        imp_sz = len(pe_import_bytes(imp, 0, 0));
        dsecs2 += pe_sec(".idata", imp_sz, 0, 0, PE_CH_RW);
        ddata2 += pe_import_bytes(imp, 0, 0);
    };
    let secs = pe_sections(textlen, bss_len, pdata, xdata, dsecs2);
    // A RUNTIME_FUNCTION's UnwindData is an RVA, and the .xdata section's
    // address is only known once pe_place has laid the sections out -- so the
    // field is patched here, from the offsets within .xdata that
    // asm.y pe_unwind_bytes recorded. Getting this wrong is invisible in the
    // headers (the Exception directory itself is still right) and fatal at the
    // first unwind, which is the worst place to find out.
    let pdata2 = pe_fix_pdata(pdata, pe_find(secs, ".xdata").rva);
    if (imp_sz > 0) {
        let idr = pe_find(secs, ".idata").rva;
        let bss_rva = pe_find(secs, ".bss").rva;
        dsecs2.foreach((_el, dj) => {
            if (dsecs2[dj].name == ".idata") {
                ddata2[dj] = pe_import_bytes(imp, idr, bss_rva);
            };
        });
    };
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
        i++;
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
    out = pe_payload(out, pd, pdata2);
    out = pe_pad(out, pd.rawptr + pd.rawsz);
    out = pe_payload(out, xd, xdata);
    out = pe_pad(out, xd.rawptr + xd.rawsz);
    // The PLACED record, not the one this function built: pe_sections hands
    // back a new list, so `dsecs2` still holds rawptr 0 and rawsz 0 -- writing
    // with those appends nothing at all (and pads to nothing), which is how
    // the -g debug sections of a PE came out empty and misplaced. Match by
    // name; every name here is unique.
    i = 0;
    while (i < len(dsecs2)) {
        let d = pe_find(secs, dsecs2[i].name);
        let dd = ddata2[i];
        out = pe_payload(out, d, dd);
        out = pe_pad(out, d.rawptr + d.rawsz);
        i++;
    };
    out = push_bytes(out, symtab);
    out
};

// The .text section's RVA, which pe_place may have left alone (it is the one
// section whose RVA is not derived from a predecessor's end).
def pe_text_rva(secs: [PeSecHdr]) -> long {
    pe_find(secs, ".text").rva
};

// Four little-endian bytes of a 32-bit value.
def pe_le32(v: long) -> [byte] {
    let out: [byte] = [];
    out += v % 256;
    out += v / 256 % 256;
    out += v / 65536 % 256;
    out += v / 16777216 % 256;
    out
};

// Add `rva` to the UnwindData field of every 12-byte RUNTIME_FUNCTION. The
// field is at offset 8; the other two are the function's begin and end
// addresses, which are already section-relative and stay as they are.
def pe_fix_pdata(pdata: [byte], rva: long) -> [byte] {
    let out: [byte] = pdata;
    let i = 0;
    while (i + 11 < len(out)) {
        let b = pe_le32(out[i + 8] + out[i + 9] * 256 + out[i + 10] * 65536 + out[i + 11] * 16777216 + rva);
        out[i + 8] = b[0];
        out[i + 9] = b[1];
        out[i + 10] = b[2];
        out[i + 11] = b[3];
        i += 12;
    };
    out
};

// Where the COFF symbol table starts: past every section's file bytes.  The
// table and its string table are in the file only -- nothing maps them.
def pe_symptr(secs: [PeSecHdr]) -> long {
    let raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    secs.foreach((_el, i) => {
        raw = raw + secs[i].rawsz;
    });
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
        if (s.chars != PE_CH_TEXT && s.chars != PE_CH_BSS) { size_init += s.rawsz; };
        i++;
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
    let id = pe_find(secs, ".idata");
    if (id.name == ".idata") {
        out = push_le32(out, id.rva);   // 1: Import -- the .idata section.
        out = push_le32(out, id.vsz);   //   A loader that cannot resolve it
    } else {                            //   refuses the image.
        out = push_bytes(out, zero8);
    };
    out = push_bytes(out, zero8);       // 2: Resource
    out = push_le32(out, pd.rva);       // 3: Exception -- .pdata.  A loader
    out = push_le32(out, pd.vsz);       //   that cannot read this refuses the
    out = push_bytes(out, zero8);       // 4: Certificate   image, so it is
    out = push_bytes(out, zero8);       // 5: BaseRelocation not optional
    i = 6;
    while (i < 16) {
        out = push_bytes(out, zero8);
        i++;
    };
    out
};

// One 40-byte section header.  The name is 8 bytes, NUL-padded, and TRUNCATED
// at 8: COFF has a "/N" form for a longer name, which costs a string table
// and a PointerToStringTable in the header, and only the .debug_* names exceed
// eight bytes ("debug_info"). Truncating loses the tail of those four names
// and nothing else: a section name is informational, every consumer keys off
// the section index or the type. A PE that needs the long form is a follow-up,
// not a correctness problem here.
def pe_shdr(out: [byte], s: PeSecHdr) -> [byte] {
    let nm = s.name;
    for i in 0..8 {
        if (i < len(nm)) { out += nm[i]; } else { out += 0; };
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