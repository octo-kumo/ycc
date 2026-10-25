// pe.y — minimal Windows PE32+ writer for `ycc --target=win`.

// A section, as this writer thinks of one before it is 40 bytes.
type PeSecHdr = { name: str, vsz: long, rva: long, rawsz: long, rawptr: long, chars: long };

// ── the numbers, in one place ────────────────────────────────────────────
let PE_IMAGE_BASE = 5368709120;      // 0x140000000
let PE_SECT_ALIGN = 4096;           // SectionAlignment
let PE_FILE_ALIGN = 512;            // FileAlignment
let PE_TEXT_RVA = 4096;             // the first section's RVA
let PE_MACHINE = 34404;             // 0x8664 IMAGE_FILE_MACHINE_AMD64
// The subsystem word is res_subsystem (target.y): 3 IMAGE_SUBSYSTEM_WINDOWS_CUI, 2 ..._WINDOWS_GUI.
// IMAGE_FILE_RELOCS_STRIPPED | EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE |
// 32BIT_MACHINE
let PE_CHARS = 291;
// .text CNT_CODE|MEM_EXECUTE|MEM_READ; .bss
// CNT_UNINITIALIZED_DATA|MEM_READ|MEM_WRITE; the rest
// CNT_INITIALIZED_DATA|MEM_READ.
let PE_CH_TEXT = 1610612768;         // 0x60000020
// A sealed .text is MEM_WRITE too: the bootstrap stub decrypts the code and
// rodata in place without a VirtualProtect import (and leaves the section
// writable, which the threat model notes).
let PE_CH_TEXT_SEALED = 3758096416;  // 0xE0000020
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
def pe_sections(textlen: long, bss_len: long, pdata: [byte], xdata: [byte], dsecs: [PeSecHdr], sealed: bool) -> [PeSecHdr] {
    let out: [PeSecHdr] = [];
    out += pe_sec(".text", textlen, PE_TEXT_RVA, 0,
        if (sealed) { PE_CH_TEXT_SEALED } else { PE_CH_TEXT });
    if (bss_len > 0) {
        out += pe_sec(".bss", bss_len, 0, 0, PE_CH_BSS);
    };
    if (len(pdata) > 0) {
        out += pe_sec(".pdata", len(pdata), 0, 0, PE_CH_R);
    };
    if (len(xdata) > 0) {
        out += pe_sec(".xdata", len(xdata), 0, 0, PE_CH_R);
    };
    dsecs.foreach((e) => { out += e; });
    pe_place(out)
};

// An unplaced section: rawsz and rawptr are zero until pe_place fills them.
def pe_sec(name: str, vsz: long, rva: long, rawptr: long, chars: long) -> PeSecHdr {
    { name: name, vsz: vsz, rva: rva, rawsz: 0, rawptr: rawptr, chars: chars }
};

def pe_place(secs: [PeSecHdr]) -> [PeSecHdr] {
    let raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    let rva = PE_TEXT_RVA;
    secs.foreach((_el, i) => {
        let s = secs[i];
        if (i > 0) { rva = pe_align(rva, PE_SECT_ALIGN); };
        let rs = pe_align(s.vsz, PE_FILE_ALIGN);
        let braw = if (s.chars == PE_CH_BSS) { pe_bss_raw(s.vsz) } else { 0 };
        if (braw > 0) {
            secs[i] = { name: s.name, vsz: s.vsz, rva: rva, rawsz: braw, rawptr: raw, chars: PE_CH_RW };
            raw = raw + braw;
        } else if (s.chars == PE_CH_BSS) {
            secs[i] = { name: s.name, vsz: s.vsz, rva: rva, rawsz: 0, rawptr: raw, chars: s.chars };
        } else {
            secs[i] = { name: s.name, vsz: s.vsz, rva: rva, rawsz: rs, rawptr: raw, chars: s.chars };
            raw = raw + rs;
        };
        rva = rva + s.vsz;
    });
    secs
};

def pe_bss_raw(vsz: long) -> long {
    let n = arch.w_iat_offset(len(arch.w_imports()), 0);
    if (n == 0) { 0 } else {
        let r = pe_align(n, PE_FILE_ALIGN);
        if (r > pe_align(vsz, PE_FILE_ALIGN)) { pe_align(vsz, PE_FILE_ALIGN) } else { r }
    }
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
    for i in 0..len(s) { b[at + i] = s[i]; };
    b[at + len(s)] = 0;
};

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
    for z in 0..total { out += 0; };
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

def pe_iat_image(spec: [WImport], rva: long) -> [byte] {
    let b = pe_import_bytes(spec, rva, 0);
    let start = 20 * (len(spec) + 1);
    let n = arch.w_iat_offset(len(spec), 0);
    let out: [byte] = [];
    for k in 0..n { out += b[start + k]; };
    out
};

def pe_build(code: [byte], rodata: [byte], entry_off: long, bss_len: long, pdata: [byte], xdata: [byte], dsecs: [PeSecHdr], ddata: [[byte]], symtab: [byte], imp: [WImport], sealed: bool = false) -> [byte] {
    let codesz = len(code);
    let ro_len = len(rodata);
    let trailer: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    let textlen = codesz + ro_len + len(trailer);
    // The import section is placed with the rest, sized before its bytes can
    // be built (an RVA is only known after pe_place) and rebuilt after it.
    let dsecs2: [PeSecHdr] = [];
    let ddata2: [[byte]] = [];
    dsecs.foreach((e, di) => { dsecs2 += e; ddata2 += ddata[di]; });
    let imp_sz = 0;
    if (len(imp) > 0) {
        imp_sz = len(pe_import_bytes(imp, 0, 0));
        dsecs2 += pe_sec(".idata", imp_sz, 0, 0, PE_CH_RW);
        ddata2 += pe_import_bytes(imp, 0, 0);
    };
    let secs = pe_sections(textlen, bss_len, pdata, xdata, dsecs2, sealed);
    let pdata2 = pe_fix_pdata(pdata, pe_find(secs, ".xdata").rva);
    if (imp_sz > 0) {
        let idr = pe_find(secs, ".idata").rva;
        let bss_rva = pe_find(secs, ".bss").rva;
        dsecs2.foreach((e, dj) => {
            if (e.name == ".idata") {
                ddata2[dj] = pe_import_bytes(imp, idr, bss_rva);
            };
        });
    };
    let iat_img: [byte] = [];
    if (imp_sz > 0) { iat_img = pe_iat_image(imp, pe_find(secs, ".idata").rva); };
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
    let bs = pe_find(secs, ".bss");
    out = pe_payload(out, bs, iat_img);
    if (bs.rawsz > 0) { out = pe_pad(out, bs.rawptr + bs.rawsz); };
    out = pe_payload(out, pd, pdata2);
    out = pe_pad(out, pd.rawptr + pd.rawsz);
    out = pe_payload(out, xd, xdata);
    out = pe_pad(out, xd.rawptr + xd.rawsz);
    i = 0;
    while (i < len(dsecs2)) {
        let d = pe_find(secs, dsecs2[i].name);
        out = pe_payload(out, d, ddata2[i]);
        out = pe_pad(out, d.rawptr + d.rawsz);
        i++;
    };
    out = push_bytes(out, symtab);
    pe_seal(out)
};

// TimeDateStamp and CheckSum, the two header fields that depend on the whole
// file. The stamp is FNV-1a of the image with both fields zero (a function of
// the bytes, so builds stay reproducible); the checksum is the PE one: the
// 16-bit words of the file summed with carries folded back, plus the length.
def pe_seal(out: [byte]) -> [byte] {
    let n = len(out);
    let h = 2166136261;
    for k in 0..n { h = ((h ^ out[k]) * 16777619) & 4294967295; };
    pe_put32(out, 136, h);
    let sum = 0;
    let i = 0;
    while (i + 1 < n) {
        sum += out[i] + out[i + 1] * 256;
        i += 2;
    };
    if (i < n) { sum += out[i]; };
    while (sum > 65535) { sum = (sum & 65535) + (sum >> 16); };
    pe_put32(out, 216, sum + n);
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
    secs.foreach((e) => {
        raw = raw + e.rawsz;
    });
    raw
};

// ── headers ──────────────────────────────────────────────────────────────
def pe_dos(out: [byte]) -> [byte] {
    let hdr: [byte] = [
        77, 90, 144, 0, 3, 0, 0, 0, 4, 0, 0, 0, 255, 255, 0, 0,
        184, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0
    ];
    out = push_bytes(out, hdr);
    // push cs; pop ds; mov dx,0x0E; mov ah,9; int 21h; mov ax,4C01h; int 21h
    let stub: [byte] = [
        14, 31, 186, 14, 0, 180, 9, 205, 33, 184, 1, 76, 205, 33
    ];
    out = push_bytes(out, stub);
    out = push_bytes(out, pe_dos_msg());
    pe_pad(out, 0x80)
};

// "This program cannot be run in DOS mode.\r\r\n$", the text every linker's stub
// prints (the stub's `mov dx, 0x0E` points at it).
def pe_dos_msg() -> [byte] {
    let m = "This program cannot be run in DOS mode.";
    let out: [byte] = [];
    for i in 0..len(m) { out += m[i]; };
    out += 13;
    out += 13;
    out += 10;
    out += 36;
    out
};

def pe_coff(out: [byte], nsec: long, symtab: [byte], symptr: long) -> [byte] {
    out = push_le32(out, 0x4550);       // "PE\0\0", at e_lfanew
    out = push_le16(out, PE_MACHINE);
    out = push_le16(out, nsec);
    // TimeDateStamp 0 here; pe_seal fills it with a hash of the image (the
    // /Brepro convention) so the bytes stay a function of the source alone.
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
    out = push_le16(out, 14);           // linker version 14.0 (major 14, minor 0)
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
    out = push_le16(out, 1);            // MajorImageVersion
    out = push_le16(out, 0);            // MinorImageVersion
    out = push_le16(out, 6);            // MajorSubsystemVersion
    out = push_le16(out, 0);            // MinorSubsystemVersion
    out = push_le32(out, 0);            // Win32VersionValue
    out = push_le32(out, size_image);
    out = push_le32(out, size_headers);
    out = push_le32(out, 0);            // CheckSum: pe_seal fills it in
    out = push_le16(out, if (res_subsystem == 0) { 3 } else { res_subsystem });
    // DllCharacteristics NX_COMPAT (0x100) | TERMINAL_SERVER_AWARE (0x8000).
    // No DYNAMIC_BASE: there is no .reloc for it to act on, and fork copies
    // the heap (type descriptors, code pointers) into a child at the same
    // addresses, which a moved image would break.
    out = push_le16(out, 33024);
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
