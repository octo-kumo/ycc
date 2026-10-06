// pe.c — minimal Windows PE32+ writer for `ycc --target=windows`.
// 1:1 port of src/y/pe.y (see PORTING.md). Same defs in the same order,
// same control flow, same bytes out. The comment that carries the design
// (no .reloc needed; .pdata/.xdata not optional) is in pe.h.
//
// The Y twin indexes a section record as `s.name` / `s.vsz`; here every field
// read goes through yr_get(rec, "name") because the C copy SHARES records
// (yv.h) — a field read must go through the record the value lives in.
// Assigning a whole record is `ya_set(secs, i, pe_sec(...))`, the twin of
// `secs[i] = {...}`, which the Y copy also does in place (it shares records
// too, so the two agree).
#include "ylong.h"
#include "pe.h"
#include "elf.h"
#include "enc64.h"
#include "arch_x64.h"

/* imported */
/* none — pe.y calls no other module's defs. The helpers it needs
   (push_bytes, push_zeros, push_le16/32/64, byte_of) are elf.c's and
   enc64.c's, and are C functions here exactly as they are C functions in the
   ELF writer, which is why pe.h declares pe_build and friends rather than
   every one of them. */

/* ── the numbers, in one place ────────────────────────────────────────────
   ImageBase 0x140000000: the conventional x64 EXE base, and because
   RELOCS_STRIPPED is set the image MUST load exactly here. Anything that
   cannot have 0x140000000 free fails to load -- the price of not emitting a
   .reloc, and the price every hand-written no-reloc PE pays.

   The main stack: 8 MB reserved, 64 KB committed. Linux leaves the stack to
   the kernel default (8 MB); a program that spawns a thread asks for its own
   8 MB mapping (arch/threads.s), so the main thread gets the same reserve
   here and a deep recursion has the same room on both targets.

   (The other constants: PE_SECT_ALIGN 4096 SectionAlignment, PE_FILE_ALIGN
   512 FileAlignment, PE_TEXT_RVA 4096 the first section's RVA, PE_MACHINE
   34404 = 0x8664 IMAGE_FILE_MACHINE_AMD64, PE_SUBSYSTEM 3
   IMAGE_SUBSYSTEM_WINDOWS_CUI, PE_CHARS 291 =
   RELOCS_STRIPPED|EXECUTABLE_IMAGE|LARGE_ADDRESS_AWARE|32BIT_MACHINE,
   PE_CH_TEXT 0x60000020 .text CNT_CODE|MEM_EXECUTE|MEM_READ, PE_CH_BSS
   0xC0000080 .bss CNT_UNINITIALIZED_DATA|MEM_READ|MEM_WRITE, PE_CH_R
   0x40000040 the rest CNT_INITIALIZED_DATA|MEM_READ. All written as decimal
   longs here exactly as the Y twin writes them, so a reader can diff the two
   files line for line.) */
#define PE_IMAGE_BASE 5368709120LL      /* 0x140000000 */
#define PE_TEXT_RVA 4096LL              /* the first section's RVA */
#define PE_SECT_ALIGN 4096LL            /* SectionAlignment */
#define PE_FILE_ALIGN 512LL             /* FileAlignment */
#define PE_MACHINE 34404LL              /* 0x8664 IMAGE_FILE_MACHINE_AMD64 */
#define PE_SUBSYSTEM 3LL                /* IMAGE_SUBSYSTEM_WINDOWS_CUI */
#define PE_CHARS 291LL
#define PE_CH_TEXT 1610612768LL         /* 0x60000020 */
#define PE_CH_BSS 3221225600LL          /* 0xC0000080 */
/* INITIALIZED_DATA|MEM_READ|MEM_WRITE (0xC0000040): the import section. It has
   file bytes (the ILT, which is what a loader that does not resolve an import
   leaves behind) and the loader WRITES the resolved addresses over the IAT in
   the same pages, so it cannot be read-only. */
#define PE_CH_RW 3221225536LL           /* 0xC0000040 */
#define PE_CH_R 1073741888LL            /* 0x40000040 */
#define PE_STACK_RESERVE 8388608LL
#define PE_STACK_COMMIT 65536LL

/* Round V up to a multiple of A (A a power of two). */
ylong pe_align(ylong v, ylong a) {
    ylong r = v % a;
    if (r == 0) { return v; }
    else { return v + a - r; }
}

/* The RVA of the .bss section: the first page past .text's virtual size. A
   .bss label resolves through pe_bss_from_ro, so the plain and the -g build
   cannot each have their own formula for it -- the contract
   elf_bss_from_ro has for the ELF side. */
ylong pe_bss_from_ro(ylong code_len, ylong ro_len, ylong bss_len) {
    return pe_align(code_len + ro_len + 8, PE_SECT_ALIGN) - code_len;
}

/* The address the DWARF line table's offsets hang off: ImageBase + .text. */
ylong pe_text_base(void) {
    return PE_IMAGE_BASE + PE_TEXT_RVA;
}

/* DOS header (64) + stub pad to 0x80, PE signature (4), COFF header (20),
   optional header (240), one 40-byte section header per section. */
ylong pe_headers_size(Yv *secs) {
    return 0x80 + 4 + 20 + 240 + 40 * yv_len(secs);
}

/* An unplaced section: rawsz and rawptr are zero until pe_place fills them. */
Yv *pe_sec(Yv *name, ylong vsz, ylong rva, ylong rawptr, ylong chars) {
    return yr(6, "name", name, "vsz", yv_long(vsz), "rva", yv_long(rva),
              "rawsz", yv_long(0), "rawptr", yv_long(rawptr), "chars",
              yv_long(chars));
}

/* The section named `nm`, or an all-zero record when there is none (a data
   directory entry needs a zero, not a missing section). */
Yv *pe_find(Yv *secs, Yv *nm) {
    ylong i = 0;
    Yv *found = pe_sec(ys(""), 0, 0, 0, 0);
    while (i < yv_len(secs)) {
        if (ys_eq(yr_get(ya_get(secs, i), "name"), nm)) {
            found = ya_get(secs, i);
        }
        i = i + 1;
    }
    return found;
}

/* Give every section its RVA and its file offset. A section with no file
   bytes (the .bss) takes the file position it would have had and contributes
   nothing to it -- that is exactly what SizeOfRawData = 0 means. .text keeps
   the RVA pe_sections gave it; every other section follows, each on the next
   section-alignment boundary. */
Yv *pe_place(Yv *secs) {
    ylong raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    ylong rva = PE_TEXT_RVA;
    ylong i = 0;
    while (i < yv_len(secs)) {
        Yv *s = ya_get(secs, i);
        Yv *nm = yr_get(s, "name");
        ylong vsz = yv_l(yr_get(s, "vsz"));
        ylong chars = yv_l(yr_get(s, "chars"));
        if (i > 0) { rva = pe_align(rva, PE_SECT_ALIGN); }
        ylong rs = pe_align(vsz, PE_FILE_ALIGN);
        if (chars == PE_CH_BSS) {
            ya_set(secs, i, pe_sec(nm, vsz, rva, raw, chars));
        } else {
            /* The Y twin writes one record literal here with both rawsz and
               rawptr filled in; pe_sec leaves rawsz at zero (an UNPLACED
               section), so the two fields are set after it -- the same values,
               the same order, and in place on the shared record rather than on
               a copy (yv.h: the C copy shares records). */
            ya_set(secs, i, pe_sec(nm, vsz, rva, raw, chars));
            yr_set(ya_get(secs, i), "rawsz", yv_long(rs));
            yr_set(ya_get(secs, i), "rawptr", yv_long(raw));
            raw = raw + rs;
        }
        rva = rva + vsz;
        i = i + 1;
    }
    return secs;
}

/* The twin of pe.y's local pe_sections, which is a let-bound helper there and
   a static here because nothing outside pe_build calls it (the Y export list
   does not name it). .text always; .bss with a program that has globals;
   .pdata/.xdata when the assembler found any function (always, in practice);
   then one section per .debug_* under -g. Built as data first and given its
   RVA and file offset by pe_place, so every address is computed once, in one
   order. */
static Yv *pe_sections(ylong textlen, ylong bss_len, Yv *pdata, Yv *xdata,
                       Yv *dsecs) {
    Yv *out = yav(0);
    out = ya_push(out, pe_sec(ys(".text"), textlen, PE_TEXT_RVA, 0, PE_CH_TEXT));
    if (bss_len > 0) {
        out = ya_push(out, pe_sec(ys(".bss"), bss_len, 0, 0, PE_CH_BSS));
    }
    if (yv_len(pdata) > 0) {
        out = ya_push(out, pe_sec(ys(".pdata"), yv_len(pdata), 0, 0, PE_CH_R));
    }
    if (yv_len(xdata) > 0) {
        out = ya_push(out, pe_sec(ys(".xdata"), yv_len(xdata), 0, 0, PE_CH_R));
    }
    ylong i = 0;
    while (i < yv_len(dsecs)) {
        out = ya_push(out, ya_get(dsecs, i));
        i = i + 1;
    }
    return pe_place(out);
}

/* The section's bytes, when it has any: a section with no file bytes writes
   nothing, and the caller's pad lines the file position up. */
static Yv *pe_payload(Yv *out, Yv *sec, Yv *data) {
    if (yv_l(yr_get(sec, "rawsz")) == 0) { return out; }
    else { return push_bytes(out, data); }
}

static Yv *pe_pad(Yv *out, ylong upto) {
    return push_zeros(out, upto - yv_len(out));
}

/* The .text section's RVA, which pe_place may have left alone (it is the one
   section whose RVA is not derived from a predecessor's end). */
static ylong pe_text_rva(Yv *secs) {
    return yv_l(yr_get(pe_find(secs, ys(".text")), "rva"));
}

/* Four little-endian bytes of a 32-bit value, as a [byte]. */
static Yv *pe_le32(ylong v) {
    Yv *out = yav(0);
    out = ya_push(out, yv_long(v % 256));
    out = ya_push(out, yv_long(v / 256 % 256));
    out = ya_push(out, yv_long(v / 65536 % 256));
    out = ya_push(out, yv_long(v / 16777216 % 256));
    return out;
}

/* Add `rva` to the UnwindData field of every 12-byte RUNTIME_FUNCTION. The
   field is at offset 8; the other two are the function's begin and end
   addresses, which are already section-relative and stay as they are. */
static Yv *pe_fix_pdata(Yv *pdata, ylong rva) {
    Yv *out = pdata;
    ylong i = 0;
    while (i + 11 < yv_len(out)) {
        Yv *b = pe_le32(yv_l(ya_get(out, i + 8)) + yv_l(ya_get(out, i + 9)) * 256
                        + yv_l(ya_get(out, i + 10)) * 65536
                        + yv_l(ya_get(out, i + 11)) * 16777216 + rva);
        ya_set(out, i + 8, ya_get(b, 0));
        ya_set(out, i + 9, ya_get(b, 1));
        ya_set(out, i + 10, ya_get(b, 2));
        ya_set(out, i + 11, ya_get(b, 3));
        i = i + 12;
    }
    return out;
}

/* Where the COFF symbol table starts: past every section's file bytes. The
   table and its string table are in the file only -- nothing maps them. */
static ylong pe_symptr(Yv *secs) {
    ylong raw = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    ylong i = 0;
    while (i < yv_len(secs)) {
        raw = raw + yv_l(yr_get(ya_get(secs, i), "rawsz"));
        i = i + 1;
    }
    return raw;
}

/* The 64-byte DOS header, a 16-byte stub, then e_lfanew points at 0x80 where
   the PE signature goes. A real-mode stub is not needed (nothing loads a PE
   that way) but the MZ header and a plausible e_lfanew are, and 0x80 keeps
   the signature 8-byte aligned. */
static Yv *pe_dos(Yv *out) {
    /* The 64 bytes, written out because e_lfanew at offset 60 is 0x80 and a
       reader wants to see that in the same shape the Y twin writes it in (it
       is the one field with a value other than 0 or a signature). */
    Yv *hdr = yav(64,
        yv_long(77), yv_long(90), yv_long(144), yv_long(0), yv_long(3), yv_long(0), yv_long(0), yv_long(0),
        yv_long(4), yv_long(0), yv_long(0), yv_long(0), yv_long(255), yv_long(255), yv_long(0), yv_long(0),
        yv_long(184), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
        yv_long(64), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
        yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
        yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
        yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(0),
        yv_long(0), yv_long(0), yv_long(0), yv_long(0), yv_long(128), yv_long(0), yv_long(0), yv_long(0));
    out = push_bytes(out, hdr);
    Yv *stub = yav(16,
        yv_long(14), yv_long(31), yv_long(186), yv_long(14), yv_long(0), yv_long(180), yv_long(9), yv_long(205),
        yv_long(33), yv_long(184), yv_long(1), yv_long(76), yv_long(205), yv_long(33), yv_long(0), yv_long(0));
    out = push_bytes(out, stub);
    return pe_pad(out, 0x80);
}

static Yv *pe_coff(Yv *out, ylong nsec, Yv *symtab, ylong symptr) {
    out = push_le32(out, 0x4550);       /* "PE\0\0", at e_lfanew */
    out = push_le16(out, PE_MACHINE);
    out = push_le16(out, nsec);
    /* TimeDateStamp 0: the bytes must be a function of the source alone, so
       two builds of the same program are identical. */
    out = push_le32(out, 0);
    if (yv_len(symtab) > 0) {
        out = push_le32(out, symptr);
        out = push_le32(out, yv_len(symtab) / 18);
    } else {
        out = push_le32(out, 0);
        out = push_le32(out, 0);
    }
    out = push_le16(out, 240);          /* SizeOfOptionalHeader (PE32+) */
    return push_le16(out, PE_CHARS);
}

/* The PE32+ optional header: the fixed fields, then 16 data directories of
   which exactly one is used (Exception -> .pdata). An image with no import
   table and no .reloc needs no other directory. */
static Yv *pe_optional(Yv *out, Yv *secs, ylong size_headers, ylong size_image,
                       ylong entry_off) {
    ylong size_code = yv_l(yr_get(ya_get(secs, 0), "rawsz"));
    ylong size_init = 0;
    ylong i = 0;
    while (i < yv_len(secs)) {
        Yv *s = ya_get(secs, i);
        ylong ch = yv_l(yr_get(s, "chars"));
        if (ch != PE_CH_TEXT && ch != PE_CH_BSS) {
            size_init = size_init + yv_l(yr_get(s, "rawsz"));
        }
        i = i + 1;
    }
    out = push_le16(out, 0x20B);        /* Magic: PE32+ */
    out = push_le16(out, 0);            /* linker version 0.0, for the bytes */
    out = push_le32(out, size_code);
    out = push_le32(out, size_init);
    /* SizeOfUninitializedData: 0. The .bss is zero-filled by the loader,
       which is what SizeOfRawData = 0 says; this field only sizes what the
       linker would have emitted, and nothing here does. */
    out = push_le32(out, 0);
    out = push_le32(out, pe_text_rva(secs) + entry_off);
    out = push_le32(out, pe_text_rva(secs));
    out = push_le64(out, PE_IMAGE_BASE);
    out = push_le32(out, PE_SECT_ALIGN);
    out = push_le32(out, PE_FILE_ALIGN);
    out = push_le16(out, 6);            /* MajorOperatingSystemVersion */
    out = push_le16(out, 0);            /* MinorOperatingSystemVersion */
    out = push_le16(out, 0);            /* MajorImageVersion */
    out = push_le16(out, 0);            /* MinorImageVersion */
    out = push_le16(out, 6);            /* MajorSubsystemVersion */
    out = push_le16(out, 0);            /* MinorSubsystemVersion */
    out = push_le32(out, 0);            /* Win32VersionValue */
    out = push_le32(out, size_image);
    out = push_le32(out, size_headers);
    out = push_le32(out, 0);            /* CheckSum: 0 for an EXE */
    out = push_le16(out, PE_SUBSYSTEM);
    /* DllCharacteristics 0: no NX_COMPAT opt-in and no DYNAMIC_BASE, because
       there is no .reloc for the latter to act on. */
    out = push_le16(out, 0);
    out = push_le64(out, PE_STACK_RESERVE);
    out = push_le64(out, PE_STACK_COMMIT);
    out = push_le64(out, 1048576);      /* SizeOfHeapReserve */
    out = push_le64(out, 4096);         /* SizeOfHeapCommit */
    out = push_le32(out, 0);            /* LoaderFlags */
    out = push_le32(out, 16);           /* NumberOfRvaAndSizes */
    Yv *pd = pe_find(secs, ys(".pdata"));
    Yv *zero8 = yav(8, yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                    yv_long(0), yv_long(0), yv_long(0), yv_long(0));
    out = push_bytes(out, zero8);       /* 0: Export */
    Yv *id = pe_find(secs, ys(".idata"));
    if (ys_eq_lit(yr_get(id, "name"), ".idata")) {
        out = push_le32(out, yv_l(yr_get(id, "rva")));   /* 1: Import -- .idata */
        out = push_le32(out, yv_l(yr_get(id, "vsz")));   /*   a loader that */
    } else {                                             /*   cannot resolve it */
        out = push_bytes(out, zero8);                    /*   refuses the image */
    }
    out = push_bytes(out, zero8);       /* 2: Resource */
    out = push_le32(out, yv_l(yr_get(pd, "rva")));   /* 3: Exception -- .pdata. A loader */
    out = push_le32(out, yv_l(yr_get(pd, "vsz")));   /*   that cannot read this refuses the */
    out = push_bytes(out, zero8);       /* 4: Certificate   image, so it is */
    out = push_bytes(out, zero8);       /* 5: BaseRelocation not optional */
    i = 6;
    while (i < 16) {
        out = push_bytes(out, zero8);
        i = i + 1;
    }
    return out;
}

/* One 40-byte section header. The name is 8 bytes, NUL-padded, and TRUNCATED
   at 8: COFF has a "/N" form for a longer name, which costs a string table
   and a PointerToStringTable in the header, and only the .debug_* names exceed
   eight bytes ("debug_info"). Truncating loses the tail of those four names
   and nothing else: a section name is informational, every consumer keys off
   the section index or the type. A PE that needs the long form is a follow-up,
   not a correctness problem here. */
static Yv *pe_shdr(Yv *out, Yv *s) {
    Yv *nm = yr_get(s, "name");
    ylong i = 0;
    /* ys_byte_at, NOT ya_get: the field is a str and a str is not an array --
       in the Y twin `s.name[0:8]` is a byte slice of the string, which is
       exactly the C copy's ys_byte_at. ya_get on a str reads past the header
       and traps, so a PE build died in the section headers with no diagnostic
       at all (the same trap message as a genuine bounds error, which is what
       made it slow to place). */
    while (i < 8) {
        if (i < yv_len(nm)) { out = ya_push(out, yv_long(ys_byte_at(nm, i))); }
        else { out = ya_push(out, yv_long(0)); }
        i = i + 1;
    }
    out = push_le32(out, yv_l(yr_get(s, "vsz")));
    out = push_le32(out, yv_l(yr_get(s, "rva")));
    out = push_le32(out, yv_l(yr_get(s, "rawsz")));
    out = push_le32(out, yv_l(yr_get(s, "rawptr")));
    out = push_le32(out, 0);            /* PointerToRelocations */
    out = push_le32(out, 0);            /* PointerToLinenumbers */
    out = push_le16(out, 0);            /* NumberOfRelocations */
    out = push_le16(out, 0);            /* NumberOfLinenumbers */
    return push_le32(out, yv_l(yr_get(s, "chars")));
}

/* ── the import table ───────────────────────────────────────────────────
   One DLL and one function, for now, and it is scaffolding with a purpose:
   Windows has no syscall for randomness (BCryptGenRandom), for sockets
   (Winsock) or for the console API, so the WINDOWS.md items that need those
   come in through PE imports -- and until this existed the writer had none at
   all. This emits a well-formed IMAGE_IMPORT_DESCRIPTOR for KERNEL32.dll's
   GetCurrentProcessId, so the loader's resolution path is exercised end to end
   (objdump -p reads the table, and wine refuses an image whose table is
   malformed) before anything depends on it. */
/* The imports the image carries, in the order the descriptors appear. Every
   function named here needs an IAT slot the code can reach (see pe_build), and
   every DLL named here must exist on the machine or the loader refuses the
   image -- which is why this list is short and deliberate.

   `bcrypt.dll!BCryptGenRandom` is the one the next step needs: Windows has no
   syscall for randomness, so std/crypto.y's `y_os_random` has nothing to call
   until this import exists -- and the NT half of that body is the BCrypt item
   in ideas/WINDOWS.md. It is listed here, with the table exercising two DLLs
   rather than one, so that step is only the call itself. */
/* The imports the image carries, in the order the descriptors appear -- the
   list itself is arch_x64's, because the linker has to reserve a .bss cell for
   every function named in it and that happens long before this writer runs.
   `bcrypt.dll!BCryptGenRandom` is the one std/crypto.y's `y_os_random` needs
   on NT: Windows has no syscall for randomness. */
Yv *pe_imports(void) { return w_imports(); }

/* Four little-endian bytes of `v` at `at`, in place. */
static void pe_put32(Yv *b, ylong at, ylong v) {
    ya_set(b, at, yv_long(v % 256));
    ya_set(b, at + 1, yv_long(v / 256 % 256));
    ya_set(b, at + 2, yv_long(v / 65536 % 256));
    ya_set(b, at + 3, yv_long(v / 16777216 % 256));
}

/* Eight, the low half first: every value here is an RVA, so the high half is
   zero and the second store is what makes the entry 8 bytes rather than 4. */
static void pe_put64(Yv *b, ylong at, ylong v) {
    pe_put32(b, at, v % 4294967296LL);
    pe_put32(b, at + 4, v / 4294967296LL);
}

static void pe_put_str(Yv *b, ylong at, Yv *s) {
    ylong i = 0;
    while (i < yv_len(s)) { ya_set(b, at + i, yv_long(ys_byte_at(s, i))); i = i + 1; }
    ya_set(b, at + yv_len(s), yv_long(0));
}

/* The .idata image. The layout, all offsets from the section's start:

     0   IMAGE_IMPORT_DESCRIPTOR     OriginalFirstThunk -> ILT
                                      Name               -> the DLL name
                                      FirstThunk         -> IAT
     20  a zero descriptor           the terminator
     40  the ILT                     one 8-byte RVA per function, then 0
         the IAT                     the same shape; the loader overwrites it
         hint/name entries           a 2-byte hint then the name, NUL, even
         the DLL name, NUL

   `rva` is the section's own RVA when the bytes are real, and 0 when only the
   LENGTH is wanted -- the size has to be known before placement (the section
   headers depend on it) and the RVAs are not known until after, which is why
   this is called twice. Every pointer is an RVA, which survives wherever the
   image loads, and that is what lets the image stay RELOCS_STRIPPED. */
static Yv *pe_import_bytes(Yv *spec, ylong rva, ylong bss_rva) {
    ylong nd = yv_len(spec);
    ylong descs = 20 * (nd + 1);
    Yv *ilt = yav(0);
    Yv *iat = yav(0);
    ylong at = descs;
    ylong i = 0;
    while (i < nd) {
        ilt = ya_push(ilt, yv_long(at));
        at = at + 8 * (yv_len(yr_get(ya_get(spec, i), "funcs")) + 1);
        i = i + 1;
    }
    i = 0;
    while (i < nd) {
        iat = ya_push(iat, yv_long(at));
        at = at + 8 * (yv_len(yr_get(ya_get(spec, i), "funcs")) + 1);
        i = i + 1;
    }
    Yv *hoff = yav(0);
    i = 0;
    while (i < nd) {
        Yv *row = yav(0);
        Yv *fs = yr_get(ya_get(spec, i), "funcs");
        ylong k = 0;
        while (k < yv_len(fs)) {
            row = ya_push(row, yv_long(at));
            at = at + 2 + yv_len(ya_get(fs, k)) + 1;
            if (at % 2 != 0) { at = at + 1; }
            k = k + 1;
        }
        hoff = ya_push(hoff, row);
        i = i + 1;
    }
    Yv *noff = yav(0);
    i = 0;
    while (i < nd) {
        noff = ya_push(noff, yv_long(at));
        at = at + yv_len(yr_get(ya_get(spec, i), "dll")) + 1;
        i = i + 1;
    }
    ylong total = at;
    Yv *out = yav(0);
    ylong z = 0;
    while (z < total) { out = ya_push(out, yv_long(0)); z = z + 1; }
    i = 0;
    while (i < nd) {
        ylong d = 20 * i;
        Yv *fs = yr_get(ya_get(spec, i), "funcs");
        Yv *row = ya_get(hoff, i);
        pe_put32(out, d, rva + yv_l(ya_get(ilt, i)));
        pe_put32(out, d + 12, rva + yv_l(ya_get(noff, i)));
        /* FirstThunk is where the loader WRITES the resolved addresses: the
           .bss cells w_iat_offset names (the block that starts .bss, so the
           code's `mov y_iat_X(%rip), %rax` and this agree by construction),
           with a zeroed terminator cell after each DLL's functions. */
        pe_put32(out, d + 16, bss_rva + w_iat_offset(i, 0));
        ylong k = 0;
        while (k < yv_len(fs)) {
            pe_put64(out, yv_l(ya_get(ilt, i)) + 8 * k, rva + yv_l(ya_get(row, k)));
            pe_put64(out, yv_l(ya_get(iat, i)) + 8 * k, rva + yv_l(ya_get(row, k)));
            pe_put_str(out, yv_l(ya_get(row, k)) + 2, ya_get(fs, k));
            k = k + 1;
        }
        pe_put_str(out, yv_l(ya_get(noff, i)), yr_get(ya_get(spec, i), "dll"));
        i = i + 1;
    }
    return out;
}
Yv *pe_build(Yv *code, Yv *rodata, ylong entry_off, ylong bss_len, Yv *pdata,
             Yv *xdata, Yv *dsecs, Yv *ddata, Yv *symtab, Yv *imp) {
    ylong codesz = yv_len(code);
    ylong ro_len = yv_len(rodata);
    Yv *trailer = yav(8, yv_long(0), yv_long(0), yv_long(0), yv_long(0),
                      yv_long(0), yv_long(0), yv_long(0), yv_long(0));
    ylong textlen = codesz + ro_len + yv_len(trailer);
    /* The import section is placed with the rest, sized before its bytes can
       be built (an RVA is only known after pe_place) and rebuilt after it. */
    Yv *dsecs2 = yav(0);
    Yv *ddata2 = yav(0);
    ylong di = 0;
    while (di < yv_len(dsecs)) {
        dsecs2 = ya_push(dsecs2, ya_get(dsecs, di));
        ddata2 = ya_push(ddata2, ya_get(ddata, di));
        di = di + 1;
    }
    ylong imp_sz = 0;
    if (yv_len(imp) > 0) {
        imp_sz = yv_len(pe_import_bytes(imp, 0, 0));
        dsecs2 = ya_push(dsecs2, pe_sec(ys(".idata"), imp_sz, 0, 0, PE_CH_RW));
        ddata2 = ya_push(ddata2, pe_import_bytes(imp, 0, 0));
    }
    Yv *secs = pe_sections(textlen, bss_len, pdata, xdata, dsecs2);
    /* A RUNTIME_FUNCTION's UnwindData is an RVA, and the .xdata section's
       address is only known once pe_place has laid the sections out -- so the
       field is patched here, from the offsets within .xdata that asm.c
       pe_unwind_bytes recorded. Getting this wrong is invisible in the
       headers (the Exception directory itself is still right) and fatal at the
       first unwind, which is the worst place to find out. */
    Yv *pdata2 = pe_fix_pdata(pdata, yv_l(yr_get(pe_find(secs, ys(".xdata")), "rva")));
    if (imp_sz > 0) {
        ylong idr = yv_l(yr_get(pe_find(secs, ys(".idata")), "rva"));
        ylong bss_rva = yv_l(yr_get(pe_find(secs, ys(".bss")), "rva"));
        ylong dj = 0;
        while (dj < yv_len(dsecs2)) {
            if (ys_eq_lit(yr_get(ya_get(dsecs2, dj), "name"), ".idata")) {
                ya_set(ddata2, dj, pe_import_bytes(imp, idr, bss_rva));
            }
            dj = dj + 1;
        }
    }
    ylong size_headers = pe_align(pe_headers_size(secs), PE_FILE_ALIGN);
    ylong size_image = pe_align(pe_text_rva(secs) + textlen, PE_SECT_ALIGN);
    Yv *last = ya_get(secs, yv_len(secs) - 1);
    if (yv_l(yr_get(last, "vsz")) > 0) {
        ylong tail = pe_align(yv_l(yr_get(last, "rva"))
                             + yv_l(yr_get(last, "vsz")), PE_SECT_ALIGN);
        if (tail > size_image) { size_image = tail; }
    }
    Yv *out = yav(0);
    out = pe_dos(out);
    out = pe_coff(out, yv_len(secs), symtab, pe_symptr(secs));
    out = pe_optional(out, secs, size_headers, size_image, entry_off);
    ylong i = 0;
    while (i < yv_len(secs)) {
        out = pe_shdr(out, ya_get(secs, i));
        i = i + 1;
    }
    out = pe_pad(out, size_headers);
    /* .text: code, rodata, the 8-byte zero trailer. */
    Yv *t = ya_get(secs, 0);
    Yv *pd = pe_find(secs, ys(".pdata"));
    Yv *xd = pe_find(secs, ys(".xdata"));
    out = pe_payload(out, t, code);
    out = pe_payload(out, t, rodata);
    out = pe_payload(out, t, trailer);
    out = pe_pad(out, yv_l(yr_get(t, "rawptr")) + yv_l(yr_get(t, "rawsz")));
    out = pe_payload(out, pd, pdata2);
    out = pe_pad(out, yv_l(yr_get(pd, "rawptr")) + yv_l(yr_get(pd, "rawsz")));
    out = pe_payload(out, xd, xdata);
    out = pe_pad(out, yv_l(yr_get(xd, "rawptr")) + yv_l(yr_get(xd, "rawsz")));
    /* The PLACED record, not the one this function built: pe_sections hands
       back a new list, so `dsecs2` still holds rawptr 0 and rawsz 0 -- writing
       with those appends nothing at all (and pads to nothing), which is how
       the -g debug sections of a PE came out empty and misplaced. Match by
       name; every name here is unique. */
    i = 0;
    while (i < yv_len(dsecs2)) {
        Yv *d = pe_find(secs, yr_get(ya_get(dsecs2, i), "name"));
        Yv *dd = ya_get(ddata2, i);
        out = pe_payload(out, d, dd);
        out = pe_pad(out, yv_l(yr_get(d, "rawptr")) + yv_l(yr_get(d, "rawsz")));
        i = i + 1;
    }
    out = push_bytes(out, symtab);
    return out;
}