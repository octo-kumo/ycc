/* asm.h — exported surface of asm.c, the 1:1 port of src/y/asm.y.
 *
 * Assembler for the native backend's x86-64 dialect:
 * asm_assemble(text, debug) -> {ok, bytes, error, times}.
 * Only what native.y/arch_x64.y emit is accepted; anything else is a loud
 * error with a line number — never a silent miscompile. Two passes:
 * (1) parse + encode with zeroed label fields, recording fixups;
 * (2) resolve labels and patch. All jumps/calls use rel32 (fixed size), so
 * instruction lengths are known in pass 1.
 *
 * Mirrors `export { asm_assemble, ycc_assemble, labmap_new, labmap_put,
 * labmap_get };` from asm.y. The labmap is the assembler's own open-addressing
 * label table; native.y reuses it for the tree shaker's name -> index table,
 * so it is exported too (see namemap_build in native.c).
 */
#ifndef ASM_H
#define ASM_H

#include "yv.h"

Yv *asm_assemble(Yv *text, int debug);
Yv *ycc_assemble(Yv *asm_text, int debug);

Yv *labmap_new(long cap);
Yv *labmap_put(Yv *m, Yv *name, long sec, long off);
Yv *labmap_get(Yv *m, Yv *name);

#endif /* ASM_H */
