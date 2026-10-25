// ── the instruction IR ──────────────────────────────────────────────────
import labels from "./labels.y";

// Each item is eight words: form ID followed by up to seven operand fields.
const IR_W = 8;

// Not instructions (see the header).
// Numbered clear of the forms (which run 0 .. ir_nforms() - 1, under 200): a
// test `f < IR_LABEL` says "a form", and the pack writes either as one byte.
const IR_LABEL = 200;  // 1: a label id -- `yfn_3_foo:`
const IR_LOC = 201;    // 2: file, line -- `.loc 1 42` (-g)
const IR_TEXT = 202;   // 1: index into the body's raw lines

// Constants and the runtime descriptors share a compile-time schema.
import forms from "./ir_forms.y";

// Shared machine-IR registers, in x86 encoding order (enc64 uses them directly;
// enc_a64 maps them onto AArch64 registers and lowers the operations):
// enc64's reg_num is the same table:
// %rax %rcx %rdx %rbx %rsp %rbp %rsi %rdi %r8..%r15, and %xmm0..).
const R_RAX = 0;
const R_RCX = 1;
const R_RDX = 2;
const R_RSP = 4;
const R_RBP = 5;
const R_RSI = 6;
const R_RDI = 7;
const R_R8 = 8;
const R_R10 = 10;
const R_R11 = 11;
const R_R14 = 14;
const R_R15 = 15;
const R_XMM0 = 0;   // the SSE registers number from zero again, in their own
const R_XMM1 = 1;   // set: an item's size field says which set it is in

// The form `f`, building the table on first use.
def ir_form(f: long) -> IrForm {
    if (!ir_ready) { ir_init(); };
    ir_tab[f]
};

// How many forms there are (form ids run 0 .. ir_nforms() - 1).
def ir_nforms() -> long {
    if (!ir_ready) { ir_init(); };
    len(ir_tab)
};

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

def ir_render_mem(ir: [long], at: long, nodisp: bool) -> str {
    // The operand's five words start AT `at`: base, index, scale, disp, label.
    let ml = ir[at + 4];
    if (ml >= 0) {
        lname(ml) + "(%rip)"
    } else {
        let disp = ir[at + 3];
        let idx = ir[at + 1];
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
def ir_render(ir: [long], txt: [str], at: long, fno: long) -> str {
    let f = ir[at];
    if (f == IR_LABEL) {
        lname(ir[at + 1]) + ":"
    } else if (f == IR_LOC) {
        // the file number the unit's own table numbers from 1, moved by the
        // part's offset -- what asm_ir_loc does with it, so a `-g -S` listing
        // is the text the assembler consumed
        ".loc " + tostring(ir[at + 1] + fno) + " " + tostring(ir[at + 2])
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
            line = i == 0 ? line + " " + op : line + ", " + op;
            w = w + ir_kind_words(kinds[i]);
            i++;
        };
        line
    }
};

// Serialized fields for instructions and the three pseudo forms.
def ir_layout(f: long) -> str {
    if (f == IR_LABEL) { "l" }
    else if (f == IR_LOC) { "ww" }
    else if (f == IR_TEXT) { "w" }
    else { ir_form(f).wire }
};

def ir_render_all(ir: [long], txt: [str], locs: bool, fno: long) -> str {
    let out: [str] = [];
    let at = 0;
    while (at < len(ir)) {
        if (locs || ir[at] != IR_LOC) {
            out += ir_render(ir, txt, at, fno);
        };
        at += IR_W;
    };
    join(out, "\n")
};
