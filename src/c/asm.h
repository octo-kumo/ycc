/* asm.h — exported surface of asm.c, the 1:1 port of src/y/asm.y.
 *
 * Assembler for the native backend's x86-64 dialect:
 * asm_assemble(parts, debug) -> {ok, bytes, error, times, items}.
 * Only what native.y/arch_x64.y emit is accepted; anything else is a loud
 * error with a line number — never a silent miscompile. Two passes:
 * (1) parse + encode with zeroed label fields, recording fixups;
 * (2) resolve labels and patch. All jumps/calls use rel32 (fixed size), so
 * instruction lengths are known in pass 1.
 *
 * Mirrors `export { asm_assemble, ycc_assemble, part_ir, part_text, LinkPart,
 * labmap_new, labmap_put, labmap_get, hash_str };` from asm.y. The labmap is the
 * assembler's own open-addressing
 * label table; native.y reuses it for the tree shaker's name -> index table,
 * so it is exported too (see namemap_build in native.c).
 */
#ifndef ASM_H
#define ASM_H

#include "yv.h"

Yv *asm_assemble(Yv *parts, int debug);
Yv *ycc_assemble(Yv *parts, int debug);
/* A part of the assembly to assemble: a body's IR items (`ir`, with the raw
 * lines its IR_TEXT items index in `txt`), or a piece of assembly text. A
 * record is a Yv* here, so LinkPart has no declaration of its own -- the
 * export in asm.y is for the Y side's callers. */
Yv *part_ir(Yv *ir, Yv *txt, long fno, int loc);
Yv *part_text(Yv *text);

Yv *labmap_new(long cap);
long hash_str(Yv *s);   /* the name hash, and an object's checksum */
Yv *labmap_put(Yv *m, Yv *name, long sec, long off);
Yv *labmap_get(Yv *m, Yv *name);

#endif /* ASM_H */
