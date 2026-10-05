// ── the instruction IR ──────────────────────────────────────────────────
// One flat `[long]` per body, IR_W words per item:
//
//     word 0    the form (see the table below)
//     words 1.. the form's fields, in operand order: each operand consumes
//               the number of fields its kind says (see O_*)
//
// 91 forms cover every instruction the emitter writes (measured on ycc.y and
// the whole test corpus: 480,182 instructions, 91 distinct (mnemonic, operand
// shape) pairs, the top 31 of them 99.2% of the instructions). A `[long]`
// rather than the plan's packed `[byte]`: the same buffer in both compilers
// without a byte order to get wrong, and 235,092 items of eight words is
// 15 MB against the 593 MB the text and its `Operand` records cost today.
//
// An item is not always an instruction: IR_LABEL, IR_LOC and IR_TEXT carry a
// label definition, a `.loc` marker and a line of raw text (the three comment
// lines the emitter writes, and -- until stage 2b -- anything the emitter
// still spells as text). Everything else is a form.
//
// `ir_render` prints an item back as the text it replaces, byte for byte: it
// runs only under -S and for a body that is still handed to the assembler as
// text (asm.y lexes it), so the emitted bytes do not depend on it being right
// until then.
import labels from "./labels.y";

const IR_W = 8;

// Operand kinds: how many fields an operand takes, and what they mean.
const O_REG = 1;   // 2: register number, size (64/32/8/128)
const O_IND = 2;   // 2: register number, size -- `*%rax`, a closure's code
const O_IMM = 3;   // 1: the immediate
const O_LBL = 4;   // 1: a label id -- `call foo`, `jmp yL_1_2`
const O_DIFF = 5;  // 2: two label ids -- `mov $A-B, %rax`
const O_MEM = 6;   // 5: base, index, scale, disp, label. The label is a symbol
                    // at (%rip) -- no base, no index -- and the assembler
                    // resolves it; it is -1 in every other memory operand, and
                    // disp is written only when it is not O_MEM0.
const O_FS = 7;    // 1: the %fs:N offset (a thread's heap block)
const O_MEM0 = 8;  // 5, like O_MEM, but `(%base)`: no displacement written

// Not instructions (see the header).
const IR_LABEL = 97;  // 1: a label id -- `yfn_3_foo:`
const IR_LOC = 98;    // 2: file, line -- `.loc 1 42` (-g)
const IR_TEXT = 99;   // 1: index into the body's raw lines

// The forms. The table below is in this order and ir_init checks it, so a
// form added in the wrong place is a startup error and not a wrong encoding.
const F_PUSH_R = 0;
const F_POP_R = 1;
const F_CALL_L = 2;
const F_CALL_IND = 3;
const F_JMP_L = 4;
const F_RET = 5;
const F_JE_L = 6;
const F_JNE_L = 7;
const F_JZ_L = 8;
const F_JNZ_L = 9;
const F_JS_L = 10;
const F_JGE_L = 11;
const F_JLE_L = 12;
const F_JL_L = 13;
const F_JG_L = 14;
const F_JB_L = 15;
const F_JNS_L = 16;
const F_SETE_R = 17;
const F_SETNE_R = 18;
const F_SETL_R = 19;
const F_SETG_R = 20;
const F_SETGE_R = 21;
const F_SETLE_R = 22;
const F_SETA_R = 23;
const F_SETAE_R = 24;
const F_SETNP_R = 25;
const F_SETP_R = 26;
const F_MOV_R_R = 27;
const F_MOV_R_D = 28;
const F_MOV_R_P = 29;
const F_MOV_R_0 = 30;
const F_MOV_R_M = 31;
const F_MOV_D_R = 32;
const F_MOV_P_R = 33;
const F_MOV_0_R = 34;
const F_MOV_M_R = 35;
const F_MOV_I_R = 36;
const F_MOV_I_D = 37;
const F_MOV_I_0 = 38;
const F_MOV_I_M = 39;
const F_MOV_X_R = 40;
const F_MOVB_R_D = 41;
const F_MOVB_R_0 = 42;
const F_MOVB_R_M = 43;
const F_MOVB_I_D = 44;
const F_MOVB_I_0 = 45;
const F_MOVB_I_M = 46;
const F_MOVQ_R_R = 47;
const F_MOVZBQ_R_R = 48;
const F_MOVZBQ_D_R = 49;
const F_MOVZBQ_0_R = 50;
const F_MOVZBQ_M_R = 51;
const F_LEA_D_R = 52;
const F_LEA_M_R = 53;
const F_LEA_P_R = 54;
const F_ADD_I_R = 55;
const F_ADD_R_R = 56;
const F_ADD_I_D = 57;
const F_SUB_I_R = 58;
const F_SUB_R_R = 59;
const F_SUB_I_D = 60;
const F_XOR_I_R = 61;
const F_XOR_R_R = 62;
const F_XOR_I_D = 63;
const F_AND_I_R = 64;
const F_AND_R_R = 65;
const F_AND_I_D = 66;
const F_OR_R_R = 67;
const F_OR_I_D = 68;
const F_SHL_I_R = 69;
const F_SHL_R_R = 70;
const F_SAR_I_R = 71;
const F_SAR_R_R = 72;
const F_SHR_I_R = 73;
const F_SHR_R_R = 74;
const F_CMP_I_R = 75;
const F_CMP_R_R = 76;
const F_TEST_R_R = 77;
const F_IMUL_R_R = 78;
const F_IDIV_R = 79;
const F_DIV_R = 80;
const F_NEG_R = 81;
const F_NOT_R = 82;
const F_INC_R = 83;
const F_INC_D = 84;
const F_DEC_R = 85;
const F_DEC_D = 86;
const F_XCHG_R_D = 87;
const F_SYSCALL = 88;
const F_CQO = 89;
const F_MOV_F_R = 90;
const F_CVTSI2SD_R_R = 91;
const F_DIVSD_R_R = 92;
const F_MULSD_R_R = 93;
const F_ADDSD_R_R = 94;
const F_SUBSD_R_R = 95;
const F_UCOMISD_R_R = 96;

// Register numbers, x86 encoding order (enc64's reg_num is the same table:
// %rax %rcx %rdx %rbx %rsp %rbp %rsi %rdi %r8..%r15, and %xmm0..).
const R_RAX = 0;
const R_RCX = 1;
const R_RDX = 2;
const R_RBX = 3;
const R_RSP = 4;
const R_RBP = 5;
const R_RSI = 6;
const R_RDI = 7;
const R_R8 = 8;
const R_R9 = 9;
const R_R10 = 10;
const R_R11 = 11;
const R_R12 = 12;
const R_R13 = 13;
const R_R14 = 14;
const R_R15 = 15;
const R_XMM0 = 0;   // the SSE registers number from zero again, in their own
const R_XMM1 = 1;   // set: an item's size field says which set it is in
const R_XMM2 = 2;
const R_XMM3 = 3;

// A form: its mnemonic, and the kinds of its operands in order.
type IrForm = { id: long, mn: str, kinds: [long] };

let ir_tab: [IrForm] = [];
let ir_ready = false;

def ir_init() {
    let t: [IrForm] = [];
    t += { id: F_PUSH_R, mn: "push", kinds: [O_REG] };
    t += { id: F_POP_R, mn: "pop", kinds: [O_REG] };
    t += { id: F_CALL_L, mn: "call", kinds: [O_LBL] };
    t += { id: F_CALL_IND, mn: "call", kinds: [O_IND] };
    t += { id: F_JMP_L, mn: "jmp", kinds: [O_LBL] };
    t += { id: F_RET, mn: "ret", kinds: [] };
    t += { id: F_JE_L, mn: "je", kinds: [O_LBL] };
    t += { id: F_JNE_L, mn: "jne", kinds: [O_LBL] };
    t += { id: F_JZ_L, mn: "jz", kinds: [O_LBL] };
    t += { id: F_JNZ_L, mn: "jnz", kinds: [O_LBL] };
    t += { id: F_JS_L, mn: "js", kinds: [O_LBL] };
    t += { id: F_JGE_L, mn: "jge", kinds: [O_LBL] };
    t += { id: F_JLE_L, mn: "jle", kinds: [O_LBL] };
    t += { id: F_JL_L, mn: "jl", kinds: [O_LBL] };
    t += { id: F_JG_L, mn: "jg", kinds: [O_LBL] };
    t += { id: F_JB_L, mn: "jb", kinds: [O_LBL] };
    t += { id: F_JNS_L, mn: "jns", kinds: [O_LBL] };
    t += { id: F_SETE_R, mn: "sete", kinds: [O_REG] };
    t += { id: F_SETNE_R, mn: "setne", kinds: [O_REG] };
    t += { id: F_SETL_R, mn: "setl", kinds: [O_REG] };
    t += { id: F_SETG_R, mn: "setg", kinds: [O_REG] };
    t += { id: F_SETGE_R, mn: "setge", kinds: [O_REG] };
    t += { id: F_SETLE_R, mn: "setle", kinds: [O_REG] };
    t += { id: F_SETA_R, mn: "seta", kinds: [O_REG] };
    t += { id: F_SETAE_R, mn: "setae", kinds: [O_REG] };
    t += { id: F_SETNP_R, mn: "setnp", kinds: [O_REG] };
    t += { id: F_SETP_R, mn: "setp", kinds: [O_REG] };
    t += { id: F_MOV_R_R, mn: "mov", kinds: [O_REG, O_REG] };
    t += { id: F_MOV_R_D, mn: "mov", kinds: [O_REG, O_MEM] };
    t += { id: F_MOV_R_P, mn: "mov", kinds: [O_REG, O_MEM] };
    t += { id: F_MOV_R_0, mn: "mov", kinds: [O_REG, O_MEM0] };
    t += { id: F_MOV_R_M, mn: "mov", kinds: [O_REG, O_MEM] };
    t += { id: F_MOV_D_R, mn: "mov", kinds: [O_MEM, O_REG] };
    t += { id: F_MOV_P_R, mn: "mov", kinds: [O_MEM, O_REG] };
    t += { id: F_MOV_0_R, mn: "mov", kinds: [O_MEM0, O_REG] };
    t += { id: F_MOV_M_R, mn: "mov", kinds: [O_MEM, O_REG] };
    t += { id: F_MOV_I_R, mn: "mov", kinds: [O_IMM, O_REG] };
    t += { id: F_MOV_I_D, mn: "mov", kinds: [O_IMM, O_MEM] };
    t += { id: F_MOV_I_0, mn: "mov", kinds: [O_IMM, O_MEM0] };
    t += { id: F_MOV_I_M, mn: "mov", kinds: [O_IMM, O_MEM] };
    t += { id: F_MOV_X_R, mn: "mov", kinds: [O_DIFF, O_REG] };
    t += { id: F_MOVB_R_D, mn: "movb", kinds: [O_REG, O_MEM] };
    t += { id: F_MOVB_R_0, mn: "movb", kinds: [O_REG, O_MEM0] };
    t += { id: F_MOVB_R_M, mn: "movb", kinds: [O_REG, O_MEM] };
    t += { id: F_MOVB_I_D, mn: "movb", kinds: [O_IMM, O_MEM] };
    t += { id: F_MOVB_I_0, mn: "movb", kinds: [O_IMM, O_MEM0] };
    t += { id: F_MOVB_I_M, mn: "movb", kinds: [O_IMM, O_MEM] };
    t += { id: F_MOVQ_R_R, mn: "movq", kinds: [O_REG, O_REG] };
    t += { id: F_MOVZBQ_R_R, mn: "movzbq", kinds: [O_REG, O_REG] };
    t += { id: F_MOVZBQ_D_R, mn: "movzbq", kinds: [O_MEM, O_REG] };
    t += { id: F_MOVZBQ_0_R, mn: "movzbq", kinds: [O_MEM0, O_REG] };
    t += { id: F_MOVZBQ_M_R, mn: "movzbq", kinds: [O_MEM, O_REG] };
    t += { id: F_LEA_D_R, mn: "lea", kinds: [O_MEM, O_REG] };
    t += { id: F_LEA_M_R, mn: "lea", kinds: [O_MEM, O_REG] };
    t += { id: F_LEA_P_R, mn: "lea", kinds: [O_MEM, O_REG] };
    t += { id: F_ADD_I_R, mn: "add", kinds: [O_IMM, O_REG] };
    t += { id: F_ADD_R_R, mn: "add", kinds: [O_REG, O_REG] };
    t += { id: F_ADD_I_D, mn: "add", kinds: [O_IMM, O_MEM] };
    t += { id: F_SUB_I_R, mn: "sub", kinds: [O_IMM, O_REG] };
    t += { id: F_SUB_R_R, mn: "sub", kinds: [O_REG, O_REG] };
    t += { id: F_SUB_I_D, mn: "sub", kinds: [O_IMM, O_MEM] };
    t += { id: F_XOR_I_R, mn: "xor", kinds: [O_IMM, O_REG] };
    t += { id: F_XOR_R_R, mn: "xor", kinds: [O_REG, O_REG] };
    t += { id: F_XOR_I_D, mn: "xor", kinds: [O_IMM, O_MEM] };
    t += { id: F_AND_I_R, mn: "and", kinds: [O_IMM, O_REG] };
    t += { id: F_AND_R_R, mn: "and", kinds: [O_REG, O_REG] };
    t += { id: F_AND_I_D, mn: "and", kinds: [O_IMM, O_MEM] };
    t += { id: F_OR_R_R, mn: "or", kinds: [O_REG, O_REG] };
    t += { id: F_OR_I_D, mn: "or", kinds: [O_IMM, O_MEM] };
    t += { id: F_SHL_I_R, mn: "shl", kinds: [O_IMM, O_REG] };
    t += { id: F_SHL_R_R, mn: "shl", kinds: [O_REG, O_REG] };
    t += { id: F_SAR_I_R, mn: "sar", kinds: [O_IMM, O_REG] };
    t += { id: F_SAR_R_R, mn: "sar", kinds: [O_REG, O_REG] };
    t += { id: F_SHR_I_R, mn: "shr", kinds: [O_IMM, O_REG] };
    t += { id: F_SHR_R_R, mn: "shr", kinds: [O_REG, O_REG] };
    t += { id: F_CMP_I_R, mn: "cmp", kinds: [O_IMM, O_REG] };
    t += { id: F_CMP_R_R, mn: "cmp", kinds: [O_REG, O_REG] };
    t += { id: F_TEST_R_R, mn: "test", kinds: [O_REG, O_REG] };
    t += { id: F_IMUL_R_R, mn: "imul", kinds: [O_REG, O_REG] };
    t += { id: F_IDIV_R, mn: "idiv", kinds: [O_REG] };
    t += { id: F_DIV_R, mn: "div", kinds: [O_REG] };
    t += { id: F_NEG_R, mn: "neg", kinds: [O_REG] };
    t += { id: F_NOT_R, mn: "not", kinds: [O_REG] };
    t += { id: F_INC_R, mn: "inc", kinds: [O_REG] };
    t += { id: F_INC_D, mn: "inc", kinds: [O_MEM] };
    t += { id: F_DEC_R, mn: "dec", kinds: [O_REG] };
    t += { id: F_DEC_D, mn: "dec", kinds: [O_MEM] };
    t += { id: F_XCHG_R_D, mn: "xchg", kinds: [O_REG, O_MEM] };
    t += { id: F_SYSCALL, mn: "syscall", kinds: [] };
    t += { id: F_CQO, mn: "cqo", kinds: [] };
    t += { id: F_MOV_F_R, mn: "mov", kinds: [O_FS, O_REG] };
    t += { id: F_CVTSI2SD_R_R, mn: "cvtsi2sd", kinds: [O_REG, O_REG] };
    t += { id: F_DIVSD_R_R, mn: "divsd", kinds: [O_REG, O_REG] };
    t += { id: F_MULSD_R_R, mn: "mulsd", kinds: [O_REG, O_REG] };
    t += { id: F_ADDSD_R_R, mn: "addsd", kinds: [O_REG, O_REG] };
    t += { id: F_SUBSD_R_R, mn: "subsd", kinds: [O_REG, O_REG] };
    t += { id: F_UCOMISD_R_R, mn: "ucomisd", kinds: [O_REG, O_REG] };
    // The ids above are positions in this list; a form added in the wrong
    // place would decode and print as a different instruction, so check it.
    let i = 0;
    while (i < len(t)) {
        if (t[i].id != i) {
            eputs("INTERNAL: ir form table: " + tostring(t[i].id) + " at " + tostring(i) + "\n");
            exit(1);
        };
        i = i + 1;
    };
    ir_tab = t;
    ir_ready = true
};

// The form `f`, building the table on first use.
def ir_form(f: long) -> IrForm {
    if (!ir_ready) { ir_init(); };
    ir_tab[f]
};

// One item: `f` and its seven field words. Fields an operand does not have
// are 0 (and a memory operand's disp -1 means "none written", base/index -1
// "no register", its label field -1 "not a rip-relative label" -- see
// ir_render). A memory operand and a register take five and two of them, the
// widest form there is.
def ir_push(ir: [long], f: long, a: long, b: long, c: long, d: long, e: long, g: long, h: long) -> [long] {
    ir += f;
    ir += a;
    ir += b;
    ir += c;
    ir += d;
    ir += e;
    ir += g;
    ir += h
};

// Register `n` of `size` bits, spelled as the emitter spells it (enc64's
// reg_num/reg_size are the inverse).
def ir_reg(n: long, size: long) -> str {
    if (size == 128) {
        "%xmm" + tostring(n)
    } else if (size == 32) {
        ir_reg32(n)
    } else if (size == 8) {
        ir_reg8(n)
    } else {
        ir_reg64(n)
    }
};

def ir_reg64(n: long) -> str {
    let t: [str] = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
      "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"];
    if (n >= 0 && n < 16) { "%" + t[n] } else { "%r?" }
};

def ir_reg32(n: long) -> str {
    let t: [str] = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi",
      "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"];
    if (n >= 0 && n < 16) { "%" + t[n] } else { "%e?" }
};

def ir_reg8(n: long) -> str {
    let t: [str] = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil",
      "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"];
    if (n >= 0 && n < 16) { "%" + t[n] } else { "%b?" }
};

// A memory operand: `off(%base)`, `(%base)`, `off(%base,%idx,scale)`,
// `(%base,%idx,scale)` or `sym(%rip)`. `nodisp` (O_MEM0) prints `(%base)`
// whatever the disp word holds: the emitter spells `0(%rbp)` and `(%rax)`
// differently, and a frame slot's displacement is negative, so the spelling
// cannot come from its sign.
def ir_render_mem(ir: [long], at: long, nodisp: bool) -> str {
    // The operand's five words start AT `at`: base, index, scale, disp, label.
    let ml = ir[at + 4];
    if (ml >= 0) {
        lname(ml) + "(%rip)"
    } else {
        let disp = ir[at + 3];
        let idx = ir[at + 1];
        // The displacement is written whenever the kind says so -- but an
        // indexed operand leaves a zero one out, which is what the emitter
        // wrote (`(%rax,%rcx,8)`, and `8(%rcx,%rax,1)` beside it). The bytes
        // are the same either way: mod=00 in an SIB operand carries no
        // displacement.
        let head = "";
        if (!nodisp) {
            if (idx < 0 || disp != 0) { head = tostring(disp); };
        };
        if (idx < 0) {
            head + "(" + ir_reg(ir[at], 64) + ")"
        } else {
            head + "(" + ir_reg(ir[at], 64) + "," + ir_reg(idx, 64) + "," +
                tostring(ir[at + 2]) + ")"
        }
    }
};

// One operand of kind `k` at word `at`, as text.
def ir_render_op(k: long, ir: [long], at: long) -> str {
    if (k == O_REG) {
        ir_reg(ir[at], ir[at + 1])
    } else if (k == O_IND) {
        "*" + ir_reg(ir[at], ir[at + 1])
    } else if (k == O_IMM) {
        "$" + tostring(ir[at])
    } else if (k == O_LBL) {
        lname(ir[at])
    } else if (k == O_DIFF) {
        "$" + lname(ir[at]) + "-" + lname(ir[at + 1])
    } else if (k == O_MEM) {
        ir_render_mem(ir, at, false)
    } else if (k == O_MEM0) {
        ir_render_mem(ir, at, true)
    } else {
        "%fs:" + tostring(ir[at])
    }
};

// The item at word `at`, as the text it replaces. `txt` holds the body's raw
// lines (IR_TEXT).
def ir_render(ir: [long], txt: [str], at: long) -> str {
    let f = ir[at];
    if (f == IR_LABEL) {
        lname(ir[at + 1]) + ":"
    } else if (f == IR_LOC) {
        ".loc " + tostring(ir[at + 1]) + " " + tostring(ir[at + 2])
    } else if (f == IR_TEXT) {
        let i = ir[at + 1];
        if (i >= 0 && i < len(txt)) { txt[i] } else { "# INTERNAL: bad text item" }
    } else {
        let fo = ir_form(f);
        let line = "    " + fo.mn;
        let kinds = fo.kinds;
        let i = 0;
        let w = at + 1;
        while (i < len(kinds)) {
            let op = ir_render_op(kinds[i], ir, w);
            if (i == 0) {
                line = line + " " + op;
            } else {
                line = line + ", " + op;
            };
            w = w + ir_kind_words(kinds[i]);
            i = i + 1;
        };
        line
    }
};

// How many words an operand of kind `k` takes.
def ir_kind_words(k: long) -> long {
    if (k == O_REG || k == O_IND || k == O_DIFF) { 2 }
    else if (k == O_MEM || k == O_MEM0) { 5 }
    else { 1 }
};

// A whole body as text, one item per line: what asm.y lexes until stage 2b,
// and what -S prints.
def ir_render_all(ir: [long], txt: [str]) -> str {
    let out: [str] = [];
    let at = 0;
    while (at < len(ir)) {
        out += ir_render(ir, txt, at);
        at = at + IR_W;
    };
    join(out, "\n")
};