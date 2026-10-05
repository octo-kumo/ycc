/* enc64.h — exported surface of enc64.c, the 1:1 port of src/y/enc64.y.
 *
 * x86-64 instruction encoding for the native backend's subset.
 * Operands use the assembler's parsed forms:
 *   {k:"reg", n, size}      n = 0-15, size = 64/32/8
 *   {k:"imm", v}            signed long
 *   {k:"mem", base, idx, scale, disp, rip, lbl}  rip: bool (lbl valid),
 *     base/idx: reg numbers (-1 = none), scale 1/2/4/8, disp long
 *   {k:"lbl", name}         code label (jumps/calls)
 *   {k:"diff", a, b}        a-b as imm32 (rodata lengths)
 * An encoder writes the instruction's bytes FORWARD into a caller-owned
 * scratch through a cursor (see "the byte sink" in enc64.c) and returns
 * {at, fix, err}; the instruction is scratch[0:at].
 * Only the forms our backend emits exist here — anything else is a loud
 * error from the assembler, never a silent miscompile.
 *
 * Mirrors `export { Operand, Fixup, Encoded, MemTail, r64, reg_num, reg_size,
 * enc_insn, fixup, byte_of, scratch, le16, le32, le64 };` from enc64.y. The
 * three types have no C declaration of their own -- a record is a Yv* here --
 * so the export exists for the Y side's callers.
 */
#ifndef ENC64_H
#define ENC64_H

#include "yv.h"

Yv *r64(long n);
long reg_num(Yv *name);
long reg_size(Yv *name);
Yv *enc_insn(Yv *buf, long at, Yv *mn, Yv *ops, int lng);
Yv *enc_branch_long(Yv *buf, long at, long br, Yv *lbl);
Yv *fixup(long at, Yv *kind, Yv *lbl, Yv *lbl2);
Yv *scratch(void);
long byte_of(long v, long i);
Yv *le16(long v);
Yv *le32(long v);
Yv *le64(long v);

#endif /* ENC64_H */
