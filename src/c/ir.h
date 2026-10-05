/* ir.h -- the instruction IR (1:1 C copy of src/y/ir.y, see PORTING.md).
 *
 * A body is one flat [long]: IR_W words per item -- the form, then the seven
 * field words its operands take. The forms are the F_* constants below (the
 * table in ir.c is in that order and checks itself), the operand kinds the
 * O_* ones: how many fields an operand takes and what they mean. */
#ifndef IR_H
#define IR_H

#include "yv.h"

#define IR_W 8

/* operand kinds */
#define O_REG   1
#define O_IND   2
#define O_IMM   3
#define O_LBL   4
#define O_DIFF  5
#define O_MEM   6
#define O_FS    7
#define O_MEM0  8

/* not instructions (see the header) */
#define IR_W      8
#define IR_LABEL 98
#define IR_LOC 99
#define IR_TEXT 100

/* register numbers, x86 encoding order */
#define R_RAX  0
#define R_RCX  1
#define R_RDX  2
#define R_RBX  3
#define R_RSP  4
#define R_RBP  5
#define R_RSI  6
#define R_RDI  7
#define R_R8   8
#define R_R9   9
#define R_R10  10
#define R_R11  11
#define R_R12  12
#define R_R13  13
#define R_R14  14
#define R_R15  15
#define R_XMM0 0
#define R_XMM1 1
#define R_XMM2 2
#define R_XMM3 3

/* the forms */
#define F_PUSH_R 0
#define F_POP_R 1
#define F_CALL_L 2
#define F_CALL_IND 3
#define F_JMP_L 4
#define F_RET 5
#define F_JE_L 6
#define F_JNE_L 7
#define F_JZ_L 8
#define F_JNZ_L 9
#define F_JS_L 10
#define F_JGE_L 11
#define F_JLE_L 12
#define F_JL_L 13
#define F_JG_L 14
#define F_JB_L 15
#define F_JNS_L 16
#define F_SETE_R 17
#define F_SETNE_R 18
#define F_SETL_R 19
#define F_SETG_R 20
#define F_SETGE_R 21
#define F_SETLE_R 22
#define F_SETA_R 23
#define F_SETAE_R 24
#define F_SETNP_R 25
#define F_SETP_R 26
#define F_MOV_R_R 27
#define F_MOV_R_D 28
#define F_MOV_R_P 29
#define F_MOV_R_0 30
#define F_MOV_R_M 31
#define F_MOV_D_R 32
#define F_MOV_P_R 33
#define F_MOV_0_R 34
#define F_MOV_M_R 35
#define F_MOV_I_R 36
#define F_MOV_I_D 37
#define F_MOV_I_0 38
#define F_MOV_I_M 39
#define F_MOV_X_R 40
#define F_MOVB_R_D 41
#define F_MOVB_R_0 42
#define F_MOVB_R_M 43
#define F_MOVB_I_D 44
#define F_MOVB_I_0 45
#define F_MOVB_I_M 46
#define F_MOVQ_R_R 47
#define F_MOVZBQ_R_R 48
#define F_MOVZBQ_D_R 49
#define F_MOVZBQ_0_R 50
#define F_MOVZBQ_M_R 51
#define F_LEA_D_R 52
#define F_LEA_M_R 53
#define F_LEA_P_R 54
#define F_ADD_I_R 55
#define F_ADD_R_R 56
#define F_ADD_I_D 57
#define F_SUB_I_R 58
#define F_SUB_R_R 59
#define F_SUB_I_D 60
#define F_XOR_I_R 61
#define F_XOR_R_R 62
#define F_XOR_I_D 63
#define F_AND_I_R 64
#define F_AND_R_R 65
#define F_AND_I_D 66
#define F_OR_R_R 67
#define F_OR_I_D 68
#define F_SHL_I_R 69
#define F_SHL_R_R 70
#define F_SAR_I_R 71
#define F_SAR_R_R 72
#define F_SHR_I_R 73
#define F_SHR_R_R 74
#define F_CMP_I_R 75
#define F_CMP_R_R 76
#define F_TEST_R_R 77
#define F_IMUL_R_R 78
#define F_IDIV_R 79
#define F_DIV_R 80
#define F_NEG_R 81
#define F_NOT_R 82
#define F_INC_R 83
#define F_INC_D 84
#define F_DEC_R 85
#define F_DEC_D 86
#define F_XCHG_R_D 87
#define F_SYSCALL 88
#define F_CQO 89
#define F_MOV_F_R 90
#define F_CVTSI2SD_R_R 91
#define F_DIVSD_R_R 92
#define F_MULSD_R_R 93
#define F_ADDSD_R_R 94
#define F_SUBSD_R_R 95
#define F_UCOMISD_R_R 96
/* jmp *%reg: a jump through a register. Only the `jmp_at` builtin's, which a
 * forked child uses to enter a compiled image it mapped at a scratch address
 * (meta.c run_image) -- Y cannot spell a jump to an address it computed. */
#define F_JMP_IND 97

Yv *ir_push(Yv *ir, long f, long a, long b, long c, long d, long e, long g,
            long h);
Yv *ir_cat(Yv *a, Yv *b);        /* a + b, the array concat (yv.h has none) */
Yv *ir_form(long f);
Yv *ir_render(Yv *ir, Yv *txt, long at);
Yv *ir_render_all(Yv *ir, Yv *txt);
Yv *ir_render_op(long k, Yv *ir, long at);
Yv *ir_render_mem(Yv *ir, long at, int nodisp);
Yv *ir_reg(long n, long size);
Yv *ir_reg64(long n);
Yv *ir_reg32(long n);
Yv *ir_reg8(long n);
long ir_kind_words(long k);

#endif
