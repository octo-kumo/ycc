/* asm.h — exported surface of asm.c, the 1:1 port of src/y/asm.y.
 *
 * Assembler for the native backend's x86-64 dialect:
 * asm_assemble(text) -> {ok, bytes, error, times}.
 * Only what native.y/arch_x64.y emit is accepted; anything else is a loud
 * error with a line number — never a silent miscompile. Two passes:
 * (1) parse + encode with zeroed label fields, recording fixups;
 * (2) resolve labels and patch. All jumps/calls use rel32 (fixed size), so
 * instruction lengths are known in pass 1.
 *
 * Mirrors `export { asm_assemble, ycc_assemble };` from asm.y.
 */
#ifndef ASM_H
#define ASM_H

#include "yv.h"

Yv *asm_assemble(Yv *text);
Yv *ycc_assemble(Yv *asm_text);

#endif /* ASM_H */
