/* pe.h — minimal Windows PE32+ writer for ycc --target=windows.
 * 1:1 C copy of src/y/pe.y (see PORTING.md).
 * The ELF writer's twin (elf.c), and deliberately the same shape: code and
 * rodata in one R+X section, zeroed globals in a R+W section whose
 * SizeOfRawData is 0, no interpreter, no import table, no relocation
 * section, and every address in the image reached by a RIP-relative
 * displacement.
 *
 * WHY NO .reloc IS NEEDED (this is the load-bearing claim, not a
 * convenience): label_addr (asm.c) returns a SEGMENT OFFSET, and every
 * fixup the assembler patches is a DIFFERENCE of two such offsets -- rel32,
 * rel8, rip32 and imm32diff all subtract the instruction end from a target
 * offset, never writing an absolute address. The image therefore contains
 * no word the loader would have to add the load bias to, so it can be
 * RELOCS_STRIPPED and carry no .reloc at all. Two things keep that true:
 * enc64.c has no movabs, so a 64-bit absolute address would be silently
 * truncated rather than diagnosed, and nothing else may write one either --
 * so the fixup kinds are enumerated in asm.c's pe_no_abs, which refuses an
 * absolute one by name.
 *
 * Layout, FileAlignment 0x200 and SectionAlignment 0x1000:
 *   [DOS header + stub][PE sig][COFF hdr][optional hdr][section headers]
 *   [pad to SizeOfHeaders][.text][.bss (no file bytes)][.pdata][.xdata]
 *   [.debug_* and the COFF symbol table under -g]
 * .text holds the code, then the rodata, then 8 zero bytes: the same
 * trailing pad elf.c writes, so the word-at-a-time string loops can
 * over-read past a trailing NUL without leaving the section. .bss holds no
 * file bytes at all -- VirtualSize > SizeOfRawData is how PE says "zero me"
 * -- which is elf.c's zero-fill trick at 0x200 granularity.
 *
 * .pdata and .xdata are NOT optional (ideas/WINDOWS.md settles that): a PE
 * without them steps under a DWARF debugger but cannot backtrace. They are
 * real unwind data: one RUNTIME_FUNCTION per function (sorted by begin
 * address, which the emitted order already is) and one UNWIND_INFO per
 * function. asm.c pe_unwind builds both -- it is where the prologue lives
 * to be read from; see its note for how.
 *
 * Binary data flows through packed [byte] arrays; the driver writes it
 * directly so embedded NUL bytes are preserved.
 *
 * The Y twin's `type PeSecHdr = {name, vsz, rva, rawsz, rawptr, chars}` is a
 * Yv record here; the field reads go through yr_get(sec, "name") etc., which
 * is the twin of `sec.name` because the C copy SHARES records (yv.h): a field
 * read must go through the record it lives in, never through a copy of it. */
#ifndef PE_H
#define PE_H

#include "yv.h"

/* the Y twin's `export` list, one C prototype per def */
Yv *pe_build(Yv *code, Yv *rodata, long entry_off, long bss_len, Yv *pdata,
             Yv *xdata, Yv *dsecs, Yv *ddata, Yv *symtab);
long pe_bss_from_ro(long code_len, long ro_len, long bss_len);
long pe_text_base(void);
long pe_align(long v, long a);
Yv *pe_sec(Yv *name, long vsz, long rva, long rawptr, long chars);
Yv *pe_place(Yv *secs);
Yv *pe_find(Yv *secs, Yv *nm);
long pe_headers_size(Yv *secs);

#endif /* PE_H */