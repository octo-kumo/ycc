/* ir.c -- the instruction IR: 1:1 C copy of src/y/ir.y (see PORTING.md).
 *
 * One flat [long] per body, IR_W words per item: the form, then its seven
 * field words. 97 forms cover every instruction the emitter writes (measured
 * on ycc.y and the whole test corpus: 480,182 instructions, 97 distinct
 * (mnemonic, operand shape) pairs, the top 31 of them 99.2% of them).
 *
 * ir_render prints an item back as the text it replaces, byte for byte: it
 * runs only under -S and for a body that is still handed to the assembler as
 * text, so the emitted bytes do not depend on it being right until then. */
#include "ylong.h"
#include "ir.h"
#include "labels.h"

static Yv *ir_tab;
static int ir_ready;

static void ir_init(void) {
    Yv *t = yav(0);
    t = ya_push(t, yr(3, "id", yv_long(F_PUSH_R), "mn", ys("push"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_POP_R), "mn", ys("pop"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CALL_L), "mn", ys("call"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_CALL_IND), "mn", ys("call"), "kinds", yav(1, yv_long(O_IND))));
    t = ya_push(t, yr(3, "id", yv_long(F_JMP_L), "mn", ys("jmp"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_RET), "mn", ys("ret"), "kinds", yav(0)));
    t = ya_push(t, yr(3, "id", yv_long(F_JE_L), "mn", ys("je"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JNE_L), "mn", ys("jne"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JZ_L), "mn", ys("jz"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JNZ_L), "mn", ys("jnz"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JS_L), "mn", ys("js"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JGE_L), "mn", ys("jge"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JLE_L), "mn", ys("jle"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JL_L), "mn", ys("jl"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JG_L), "mn", ys("jg"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JB_L), "mn", ys("jb"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JNS_L), "mn", ys("jns"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETE_R), "mn", ys("sete"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETNE_R), "mn", ys("setne"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETL_R), "mn", ys("setl"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETG_R), "mn", ys("setg"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETGE_R), "mn", ys("setge"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETLE_R), "mn", ys("setle"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETA_R), "mn", ys("seta"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETAE_R), "mn", ys("setae"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETNP_R), "mn", ys("setnp"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SETP_R), "mn", ys("setp"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_R_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_R_D), "mn", ys("mov"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_R_P), "mn", ys("mov"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_R_0), "mn", ys("mov"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_R_M), "mn", ys("mov"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_D_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_P_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_0_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_M_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_I_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_I_D), "mn", ys("mov"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_I_0), "mn", ys("mov"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_I_M), "mn", ys("mov"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_X_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_DIFF), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_R_D), "mn", ys("movb"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_R_0), "mn", ys("movb"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_R_M), "mn", ys("movb"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_I_D), "mn", ys("movb"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_I_0), "mn", ys("movb"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVB_I_M), "mn", ys("movb"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVQ_R_R), "mn", ys("movq"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVZBQ_R_R), "mn", ys("movzbq"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVZBQ_D_R), "mn", ys("movzbq"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVZBQ_0_R), "mn", ys("movzbq"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVZBQ_M_R), "mn", ys("movzbq"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_LEA_D_R), "mn", ys("lea"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_LEA_M_R), "mn", ys("lea"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_LEA_P_R), "mn", ys("lea"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADD_I_R), "mn", ys("add"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADD_R_R), "mn", ys("add"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADD_I_D), "mn", ys("add"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUB_I_R), "mn", ys("sub"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUB_R_R), "mn", ys("sub"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUB_I_D), "mn", ys("sub"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_XOR_I_R), "mn", ys("xor"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_XOR_R_R), "mn", ys("xor"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_XOR_I_D), "mn", ys("xor"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_AND_I_R), "mn", ys("and"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_AND_R_R), "mn", ys("and"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_AND_I_D), "mn", ys("and"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_OR_R_R), "mn", ys("or"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_OR_I_D), "mn", ys("or"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_SHL_I_R), "mn", ys("shl"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SHL_R_R), "mn", ys("shl"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SAR_I_R), "mn", ys("sar"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SAR_R_R), "mn", ys("sar"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SHR_I_R), "mn", ys("shr"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SHR_R_R), "mn", ys("shr"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CMP_I_R), "mn", ys("cmp"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CMP_R_R), "mn", ys("cmp"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_TEST_R_R), "mn", ys("test"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_IMUL_R_R), "mn", ys("imul"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_IDIV_R), "mn", ys("idiv"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_DIV_R), "mn", ys("div"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_NEG_R), "mn", ys("neg"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_NOT_R), "mn", ys("not"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_INC_R), "mn", ys("inc"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_INC_D), "mn", ys("inc"), "kinds", yav(1, yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_DEC_R), "mn", ys("dec"), "kinds", yav(1, yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_DEC_D), "mn", ys("dec"), "kinds", yav(1, yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_XCHG_R_D), "mn", ys("xchg"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_SYSCALL), "mn", ys("syscall"), "kinds", yav(0)));
    t = ya_push(t, yr(3, "id", yv_long(F_CQO), "mn", ys("cqo"), "kinds", yav(0)));
    t = ya_push(t, yr(3, "id", yv_long(F_MOV_F_R), "mn", ys("mov"), "kinds", yav(2, yv_long(O_FS), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CVTSI2SD_R_R), "mn", ys("cvtsi2sd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_DIVSD_R_R), "mn", ys("divsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MULSD_R_R), "mn", ys("mulsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADDSD_R_R), "mn", ys("addsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUBSD_R_R), "mn", ys("subsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_UCOMISD_R_R), "mn", ys("ucomisd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_JMP_IND), "mn", ys("jmp"), "kinds", yav(1, yv_long(O_IND))));
    t = ya_push(t, yr(3, "id", yv_long(F_JAE_L), "mn", ys("jae"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JP_L), "mn", ys("jp"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JBE_L), "mn", ys("jbe"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JA_L), "mn", ys("ja"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_JNP_L), "mn", ys("jnp"), "kinds", yav(1, yv_long(O_LBL))));
    t = ya_push(t, yr(3, "id", yv_long(F_TEST_I_R), "mn", ys("test"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_OR_I_R), "mn", ys("or"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CMP_I_D), "mn", ys("cmp"), "kinds", yav(2, yv_long(O_IMM), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_XCHG_R_0), "mn", ys("xchg"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_TEST_R_R_ANY), "mn", ys("test"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVSD_R_R), "mn", ys("movsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVSD_D_R), "mn", ys("movsd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVSD_0_R), "mn", ys("movsd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVSD_R_D), "mn", ys("movsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM))));
    t = ya_push(t, yr(3, "id", yv_long(F_MOVSD_R_0), "mn", ys("movsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_MEM0))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADDSD_D_R), "mn", ys("addsd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_ADDSD_0_R), "mn", ys("addsd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUBSD_D_R), "mn", ys("subsd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SUBSD_0_R), "mn", ys("subsd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MULSD_D_R), "mn", ys("mulsd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_MULSD_0_R), "mn", ys("mulsd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_DIVSD_D_R), "mn", ys("divsd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_DIVSD_0_R), "mn", ys("divsd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_UCOMISD_D_R), "mn", ys("ucomisd"), "kinds", yav(2, yv_long(O_MEM), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_UCOMISD_0_R), "mn", ys("ucomisd"), "kinds", yav(2, yv_long(O_MEM0), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_CVTTSD2SI_R_R), "mn", ys("cvttsd2si"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_SQRTSD_R_R), "mn", ys("sqrtsd"), "kinds", yav(2, yv_long(O_REG), yv_long(O_REG))));
    t = ya_push(t, yr(3, "id", yv_long(F_PUSH_I), "mn", ys("push"), "kinds", yav(1, yv_long(O_IMM))));
    t = ya_push(t, yr(3, "id", yv_long(F_PUSH_M), "mn", ys("push"), "kinds", yav(1, yv_long(O_MEM))));
    /* The ids above are positions in this list; a form added in the wrong
       place would decode and print as a different instruction, so check it. */
    ylong i = 0;
    while (i < yv_len(t)) {
        if (yv_l(yr_get(ya_get(t, i), "id")) != i) {
            eputs_(ys_cat(ys("INTERNAL: ir form table: "),
                          ys_long(yv_l(yr_get(ya_get(t, i), "id")))));
            eputs_(ys_cat(ys(" at "), ys_long(i)));
            exit_(1);
        }
        i = i + 1;
    }
    ir_tab = t;
    ir_ready = 1;
}

/* `a + b`: the array concat, which the C value model has no builtin for (and
 * only this and one other place want it: the body being assembled around the
 * function's own items). */
Yv *ir_cat(Yv *a, Yv *b) {
    Yv *out = ya_slice(a, 0, yv_len(a));
    ylong i = 0;
    while (i < yv_len(b)) {
        out = ya_push(out, ya_get(b, i));
        i = i + 1;
    }
    return out;
}

/* The form `f`, building the table on first use. */
Yv *ir_form(ylong f) {
    if (!ir_ready) { ir_init(); }
    return ya_get(ir_tab, f);
}

/* How many forms there are (ir.y ir_nforms). */
ylong ir_nforms(void) {
    if (!ir_ready) { ir_init(); }
    return yv_len(ir_tab);
}

/* One item: `f` and its seven field words. Fields an operand does not have
 * are 0 (and a memory operand's disp is signed, base/index -1 "no register",
 * its label field -1 "not a rip-relative label" -- see ir_render_mem). A
 * memory operand and a register take five and two of them, the widest form
 * there is. */
Yv *ir_push(Yv *ir, ylong f, ylong a, ylong b, ylong c, ylong d, ylong e, ylong g,
            ylong h) {
    ir = ya_push(ir, yv_long(f));
    ir = ya_push(ir, yv_long(a));
    ir = ya_push(ir, yv_long(b));
    ir = ya_push(ir, yv_long(c));
    ir = ya_push(ir, yv_long(d));
    ir = ya_push(ir, yv_long(e));
    ir = ya_push(ir, yv_long(g));
    return ya_push(ir, yv_long(h));
}

/* Register `n` of `size` bits, spelled as the emitter spells it (enc64's
 * reg_num/reg_size are the inverse). */
Yv *ir_reg(ylong n, ylong size) {
    if (size == 128) {
        return ys_cat(ys("%xmm"), ys_long(n));
    } else if (size == 32) {
        return ir_reg32(n);
    } else if (size == 8) {
        return ir_reg8(n);
    } else {
        return ir_reg64(n);
    }
}

static const char *ir_reg64_names[16] = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp",
                                      "rsi", "rdi", "r8",  "r9",  "r10", "r11",
                                      "r12", "r13", "r14", "r15"};
static const char *ir_reg32_names[16] = {"eax", "ecx", "edx", "ebx", "esp", "ebp",
                                      "esi", "edi", "r8d", "r9d", "r10d", "r11d",
                                      "r12d", "r13d", "r14d", "r15d"};
static const char *ir_reg8_names[16] = {"al",  "cl",  "dl",  "bl",  "spl", "bpl",
                                     "sil", "dil", "r8b", "r9b", "r10b", "r11b",
                                     "r12b", "r13b", "r14b", "r15b"};

Yv *ir_reg64(ylong n) {
    if (n >= 0 && n < 16) { return ys_cat(ys("%"), ys_cstr(ir_reg64_names[n])); }
    else { return ys("%r?"); }
}

Yv *ir_reg32(ylong n) {
    if (n >= 0 && n < 16) { return ys_cat(ys("%"), ys_cstr(ir_reg32_names[n])); }
    else { return ys("%e?"); }
}

Yv *ir_reg8(ylong n) {
    if (n >= 0 && n < 16) { return ys_cat(ys("%"), ys_cstr(ir_reg8_names[n])); }
    else { return ys("%b?"); }
}

/* A memory operand: `off(%base)`, `(%base)`, `off(%base,%idx,scale)`,
 * `(%base,%idx,scale)` or `sym(%rip)`. `nodisp` (O_MEM0) prints `(%base)`
 * whatever the disp word holds: the emitter spells `0(%rbp)` and `(%rax)`
 * differently, and a frame slot's displacement is negative, so the spelling
 * cannot come from its sign. */
Yv *ir_render_mem(Yv *ir, ylong at, int nodisp) {
    /* the operand's five words start AT `at`: base, index, scale, disp, label */
    ylong ml = yv_l(ya_get(ir, at + 4));
    if (ml >= 0) {
        return ys_cat(lname(yv_long(ml)), ys("(%rip)"));
    } else {
        ylong disp = yv_l(ya_get(ir, at + 3));
        ylong idx = yv_l(ya_get(ir, at + 1));
        /* The displacement is written whenever the kind says so -- but an
           indexed operand leaves a zero one out, which is what the emitter
           wrote (`(%rax,%rcx,8)`, and `8(%rcx,%rax,1)` beside it). The bytes
           are the same either way: mod=00 in an SIB operand carries no
           displacement. */
        Yv *head = ys("");
        if (!nodisp) {
            if (idx < 0 || disp != 0) { head = ys_long(disp); }
        }
        if (idx < 0) {
            return ys_cat(head,
                          ys_cat(ys("("),
                               ys_cat(ir_reg(yv_l(ya_get(ir, at)), 64), ys(")"))));
        } else {
            return ys_cat(
                head,
                ys_cat(ys("("),
                     ys_cat(ir_reg(yv_l(ya_get(ir, at)), 64),
                          ys_cat(ys(","),
                               ys_cat(ir_reg(idx, 64),
                                    ys_cat(ys(","),
                                         ys_cat(ys_long(yv_l(ya_get(ir, at + 2))),
                                              ys(")"))))))));
        }
    }
}

/* One operand of kind `k` at word `at`, as text. */
Yv *ir_render_op(ylong k, Yv *ir, ylong at) {
    if (k == O_REG) {
        return ir_reg(yv_l(ya_get(ir, at)), yv_l(ya_get(ir, at + 1)));
    } else if (k == O_IND) {
        return ys_cat(ys("*"),
                      ir_reg(yv_l(ya_get(ir, at)),
                             yv_l(ya_get(ir, at + 1))));
    } else if (k == O_IMM) {
        return ys_cat(ys("$"), ys_long(yv_l(ya_get(ir, at))));
    } else if (k == O_LBL) {
        return lname(ya_get(ir, at));
    } else if (k == O_DIFF) {
        return ys_cat(ys("$"),
                      ys_cat(lname(ya_get(ir, at)),
                           ys_cat(ys("-"), lname(ya_get(ir, at + 1)))));
    } else if (k == O_MEM) {
        return ir_render_mem(ir, at, 0);
    } else if (k == O_MEM0) {
        return ir_render_mem(ir, at, 1);
    } else {
        return ys_cat(ys("%fs:"), ys_long(yv_l(ya_get(ir, at))));
    }
}

/* The item at word `at`, as the text it replaces. `txt` holds the body's raw
 * lines (IR_TEXT). */
Yv *ir_render(Yv *ir, Yv *txt, ylong at, ylong fno) {
    ylong f = yv_l(ya_get(ir, at));
    if (f == IR_LABEL) {
        return ys_cat(lname(ya_get(ir, at + 1)), ys(":"));
    } else if (f == IR_LOC) {
        /* the file number the unit's own table numbers from 1, moved by the
           part's offset -- what asm_ir_loc does with it, so a `-g -S` listing
           is the text the assembler consumed */
        return ys_cat(ys(".loc "),
                      ys_cat(ys_long(yv_l(ya_get(ir, at + 1)) + fno),
                           ys_cat(ys(" "),
                                ys_long(yv_l(ya_get(ir, at + 2))))));
    } else if (f == IR_TEXT) {
        ylong i = yv_l(ya_get(ir, at + 1));
        if (i >= 0 && i < yv_len(txt)) { return ya_get(txt, i); }
        else { return ys("    # INTERNAL: bad text item"); }
    } else {
        Yv *fo = ir_form(f);
        Yv *line = ys_cat(ys("    "), yr_get(fo, "mn"));
        Yv *kinds = yr_get(fo, "kinds");
        ylong i = 0;
        ylong wp = at + 1;
        while (i < yv_len(kinds)) {
            Yv *op = ir_render_op(yv_l(ya_get(kinds, i)), ir, wp);
            if (i == 0) {
                line = ys_cat(line, ys_cat(ys(" "), op));
            } else {
                line = ys_cat(line, ys_cat(ys(", "), op));
            }
            wp = wp + ir_kind_words(yv_l(ya_get(kinds, i)));
            i = i + 1;
        }
        return line;
    }
}

/* How many words an operand of kind `k` takes. */
ylong ir_kind_words(ylong k) {
    if (k == O_REG || k == O_IND || k == O_DIFF) { return 2; }
    else if (k == O_MEM || k == O_MEM0) { return 5; }
    else { return 1; }
}

/* A whole body as text, one item per line: what asm.y lexes until stage 2b,
 * and what -S prints. */
/* `locs` says whether to print the `.loc` markers: a body compiled with line
 * info carries them whatever the program asked for, and a link without -g
 * drops them (asm_ir_items drops the item, link_text drops the line). */
Yv *ir_render_all(Yv *ir, Yv *txt, int locs, ylong fno) {
    Yv *out = yav(0);
    ylong at = 0;
    while (at < yv_len(ir)) {
        if (locs || yv_l(ya_get(ir, at)) != IR_LOC) {
            out = ya_push(out, ir_render(ir, txt, at, fno));
        }
        at = at + IR_W;
    }
    return ys_join(out, ys("\n"));
}
