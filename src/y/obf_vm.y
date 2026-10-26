// obf_vm.y -- the bytecode VM layer of --ob.
//
// A selected leaf function is replaced by a native wrapper that builds a VM
// context and calls a generated interpreter. The function's final IR is
// encoded as fixed 8-word instructions; the interpreter is one native routine
// whose opcode numbers, register slots and handler order are random per build.
// Blocks stay native in the dispatch VM (obfuscate.y flatten); this layer is
// the next step: the function's own code is not executable until the
// interpreter decodes its operands.
//
// v2 supports the 64-bit integer subset that leaf helpers use: moves, loads,
// stores, lea, add/sub/xor/and/or/cmp/test, imul, shifts, neg/not, push/pop,
// branches, returns and (x86-64) calls to yfn_ labels, over frame, heap,
// global and closure-record memory (base/index/label). v3 adds the scalar
// double SSE subset (movsd, add/sub/mul/div, ucomisd, cvtsi2sd) and integer
// div/cqo on x86-64, so float helpers stay in bytecode; indirect jumps and
// AArch64 calls still fall back to the native and dispatch passes.

import insn from "./ir.y";
import lbl from "./labels.y";
import obf from "./obfuscate.y";
import wintgt from "./target.y";

const S_MOV_I_R = 0;
const S_MOV_R_R = 1;
const S_LOAD = 2;
const S_STORE = 3;
const S_STORE_I = 4;
const S_LEA = 5;
const S_ADD_I = 6;
const S_ADD_R = 7;
const S_SUB_I = 8;
const S_SUB_R = 9;
const S_XOR_I = 10;
const S_XOR_R = 11;
const S_AND_I = 12;
const S_AND_R = 13;
const S_OR_I = 14;
const S_OR_R = 15;
const S_CMP_I = 16;
const S_CMP_R = 17;
const S_TEST_I = 18;
const S_TEST_R = 19;
const S_IMUL = 20;
const S_SHL_I = 21;
const S_SAR_I = 22;
const S_SHR_I = 23;
const S_NEG = 24;
const S_NOT = 25;
const S_PUSH_R = 26;
const S_POP_R = 27;
const S_JMP = 28;
const S_RET = 29;
const S_JE = 30;
const S_JNE = 31;
const S_JZ = 32;
const S_JNZ = 33;
const S_JS = 34;
const S_JNS = 35;
const S_JL = 36;
const S_JGE = 37;
const S_JLE = 38;
const S_JG = 39;
const S_JB = 40;
const S_JAE = 41;
const S_JBE = 42;
const S_JA = 43;
const S_JP = 44;
const S_JNP = 45;
const S_CALL = 46;
const S_SETE = 47;
const S_SETNE = 48;
const S_SETL = 49;
const S_SETG = 50;
const S_SETGE = 51;
const S_SETLE = 52;
const S_SETA = 53;
const S_SETAE = 54;
const S_SETB = 55;
const S_SETBE = 56;
const S_SETP = 57;
const S_SETNP = 58;
const S_MOVZBQ = 59;
const S_MOVQ = 60;
const S_XLOAD = 61;
const S_XSTORE = 62;
const S_XMOV = 63;
const S_XADD = 64;
const S_XSUB = 65;
const S_XMUL = 66;
const S_XDIV = 67;
const S_XDIVM = 68;
const S_XUCOMI = 69;
const S_XUCOMIM = 70;
const S_XCVTSI = 71;
const S_XCVTTSI = 72;
const S_XSQRT = 73;
const S_CQO = 74;
const S_IDIV = 75;
const S_DIV = 76;
const S_MOVZBQ_M = 77;
const S_COUNT = 78;

// Context offsets. The wrapper puts the context and the label table in the
// top 8 KiB of its 64 KiB VM area; the virtual stack starts at VRS_OFF.
const CTX_PC = 0;
const CTX_CODE = 8;
const CTX_LABELS = 16;
const CTX_FLAGS = 24;   // CF ZF SF OF PF, one 8-byte cell each
const CTX_VREG = 64;    // 16 slots, 8 bytes each
const CTX_KEY = 192;    // the per-function bytecode key
const CTX_INSN = 256;   // the decoded 8-word instruction
const CTX_MAP = 320;    // per-function opcode map (diversity=high)
const CTX_XMM = 328;    // 16 low-64-bit SSE slots (scalar double)
const CTX_OFF = -512;
const VRS_OFF = -8192;
const VM_AREA = 65536;
const MAX_FRAME = 32768;
const MAX_LABELS = 512;

type VmFn = { ok: bool, ir: [long], ro: str, n: long, ret_imm: bool };
type TRes = { ok: bool, code: [long], labs: [long], lpos: [long],
    mlabs: [long], n: long, ret_imm: bool };

let vm_seed = 0;
let vm_rng = 0;
let vm_perm: [long] = [];
let vm_codes: [long] = [];
let vm_interp = -1;
let vm_high = false;
let vm_fperm: [long] = [];
let vm_xperm: [long] = [];
let vm_used = false;
let vm_tmp = 0;
let vm_bc_count = 0;

def vm_mix64(x: long) -> long {
    let z = x + 0x9E3779B97F4A7C15;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    z ^ (z >>> 31)
};

def rnd() -> long {
    vm_rng = vm_mix64(vm_rng + 0x9E3779B97F4A7C15);
    vm_rng
};

def below(n: long) -> long {
    if (n <= 0) { 0 } else { (rnd() >>> 1) % n }
};

def vm_begin(seed: long, high: bool) -> void {
    vm_seed = seed ^ 0x564D4243;
    vm_rng = vm_seed;
    vm_tmp = 0;
    vm_high = high;
    vm_fperm = [];
    vm_xperm = [];
    for i in 0..16 { vm_xperm += i; };
    let xi = 15;
    while (xi > 0) {
        let j = 1 + below(xi);
        let t = vm_xperm[xi];
        vm_xperm[xi] = vm_xperm[j];
        vm_xperm[j] = t;
        xi -= 1;
    };
    vm_used = false;
    vm_bc_count = 0;
    vm_perm = [];
    for i in 0..16 { vm_perm += i; };
    let i = 15;
    while (i > 0) {
        let j = 1 + below(i);
        let t = vm_perm[i];
        vm_perm[i] = vm_perm[j];
        vm_perm[j] = t;
        i -= 1;
    };
    vm_codes = [];
    let s = 0;
    while (s < S_COUNT) {
        let c = 1 + below(250);
        let dup = false;
        vm_codes.foreach((e) => {
            if (e == c) { dup = true; };
        });
        if (!dup) {
            vm_codes += c;
            s += 1;
        };
    };
    vm_interp = lbl.lbl_fresh("yvmx_run");
};

def opcode(s: long) -> long { vm_codes[s] };
def slot(reg: long) -> long { vm_perm[reg] };
def xslot(reg: long) -> long { vm_xperm[reg] };

// The interpreter compares the base opcode; a high-diversity build encodes
// each function through its own permutation and the decoded number is mapped
// back through that function's table before dispatch.
def enc(s: long) -> long {
    if (vm_high) { opcode(vm_fperm[s]) } else { opcode(s) }
};

def fperm_new() -> [long] {
    let o: [long] = [];
    for i in 0..S_COUNT { o += i; };
    let i = S_COUNT - 1;
    while (i > 0) {
        let j = 1 + below(i);
        let t = o[i];
        o[i] = o[j];
        o[j] = t;
        i -= 1;
    };
    o
};
def interp_label() -> long { vm_interp };
def compiled_count() -> long { vm_bc_count };
def used() -> bool { vm_used };

def fresh_tmp() -> str {
    vm_tmp += 1;
    "yvmx_t_" + tostring(vm_tmp)
};

def is_comment(line: str) -> bool {
    let i = 0;
    while (i < len(line) && (line[i] == ' ' || line[i] == '\t')) { i += 1; };
    i >= len(line) || line[i] == '#'
};

// A memory operand is virtualizable when the interpreter can form its
// address: an optional register base and index, a 1/2/4/8 scale, a
// displacement and an optional label-table entry. A bare absolute address is
// not something the emitter produces, so it is refused rather than guessed.
def mem_ok(ir: [long]) -> bool {
    let ok = true;
    let at = 0;
    while (at < len(ir) && ok) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let kinds = insn.ir_form(f).kinds;
            let w = at + 1;
            let ki = 0;
            while (ki < len(kinds) && ok) {
                let k = kinds[ki];
                if (k == insn.O_MEM || k == insn.O_MEM0) {
                    let base = ir[w];
                    let idx = ir[w + 1];
                    let scale = ir[w + 2];
                    let lid = ir[w + 4];
                    if (base < -1 || base > 15 || idx < -1 || idx > 15
                        || !(scale == 1 || scale == 2 || scale == 4
                            || scale == 8)
                        || (base < 0 && lid < 0)) {
                        ok = false;
                    };
                };
                w += insn.ir_kind_words(k);
                ki += 1;
            };
        };
        at += insn.IR_W;
    };
    ok
};

// The v1 VM area leaves about 56 KiB below the virtual stack pointer. A
// function that pushes more than this is not selected.
def stack_need(ir: [long]) -> long {
    let depth = 0;
    let max = 0;
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f == insn.F_PUSH_R || f == insn.F_PUSH_I || f == insn.F_PUSH_M) {
            depth += 1;
            if (depth > max) { max = depth; };
        } else if (f == insn.F_POP_R) {
            depth -= 1;
            if (depth < 0) { depth = 0; };
        };
        at += insn.IR_W;
    };
    max
};

def vm_has_raw_text(txt: [str]) -> bool {
    let out = false;
    txt.foreach((e) => {
        if (!is_comment(e)) { out = true; };
    });
    out
};

// ── translation ─────────────────────────────────────────────────────────

def push8(code: [long], a: long, b: long, c: long, d: long, e: long,
        f: long, g: long, h: long) -> [long] {
    insn.ir_push(code, a, b, c, d, e, f, g, h)
};

def note_label(labs: [long], lpos: [long], id: long, pos: long) -> void {
    let i = 0;
    let found = false;
    while (i < len(labs) && !found) {
        if (labs[i] == id) { found = true; };
        i += 1;
    };
    if (!found) {
        labs += id;
        lpos += pos;
    };
};

def find_pos(labs: [long], lpos: [long], id: long) -> long {
    let out = -1;
    let i = 0;
    while (i < len(labs) && out < 0) {
        if (labs[i] == id) { out = lpos[i]; };
        i += 1;
    };
    out
};

def mem_label(mlabs: [long], id: long) -> long {
    let out = -1;
    let i = 0;
    while (i < len(mlabs) && out < 0) {
        if (mlabs[i] == id) { out = i; };
        i += 1;
    };
    if (out < 0) {
        mlabs += id;
        out = len(mlabs) - 1;
    };
    out
};

def emit_mem(code: [long], ir: [long], w: long, mlabs: [long], mem0: bool) -> [long] {
    let base = ir[w];
    let idx = ir[w + 1];
    let scale = ir[w + 2];
    let shift = 0;
    if (scale == 2) { shift = 1; }
    else if (scale == 4) { shift = 2; }
    else if (scale == 8) { shift = 3; };
    let disp = 0;
    if (!mem0) { disp = ir[w + 3]; };
    let lid = ir[w + 4];
    let bi = -1;
    let ii = -1;
    let li = -1;
    if (base >= 0) { bi = slot(base); };
    if (idx >= 0) { ii = slot(idx); };
    if (lid >= 0) { li = mem_label(mlabs, lid); };
    let o = code;
    o += bi;
    o += ii;
    o += shift;
    o += disp;
    o += li;
    o
};

def fail_res() -> TRes {
    { ok: false, code: [], labs: [], lpos: [], mlabs: [], n: 0,
        ret_imm: false }
};

// The arguments a body reads from positive %rbp offsets. A Y def's `ret $n`
// names them; a closure body ends in a plain `ret`, and this is the only
// source of its argument count.
def incoming_args(ir: [long]) -> long {
    let out = 0;
    let at = 0;
    while (at < len(ir)) {
        let f = ir[at];
        if (f < insn.IR_LABEL) {
            let kinds = insn.ir_form(f).kinds;
            let w = at + 1;
            let ki = 0;
            while (ki < len(kinds)) {
                let k = kinds[ki];
                if ((k == insn.O_MEM || k == insn.O_MEM0)
                    && ir[w] == insn.R_RBP && ir[w + 4] < 0 && ir[w + 3] >= 16) {
                    let n = (ir[w + 3] - 16) / 8 + 1;
                    if (n > out) { out = n; };
                };
                w += insn.ir_kind_words(k);
                ki += 1;
            };
        };
        at += insn.IR_W;
    };
    out
};

def ret_n(f: long, ir: [long], at: long) -> long {
    if (f == insn.F_RET_I) { ir[at + 1] / 8 } else { 0 }
};

def translate(ir: [long], txt: [str]) -> TRes {
    if (vm_has_raw_text(txt) || !mem_ok(ir) || len(ir) == 0
        || ir[0] != insn.IR_LABEL) {
        fail_res()
    } else {
        vm_fperm = [];
        if (vm_high) { vm_fperm = fperm_new(); };
        let code: [long] = [];
        let labs: [long] = [];
        let lpos: [long] = [];
        let mlabs: [long] = [];
        let brword: [long] = [];
        let brlab: [long] = [];
        let n = -1;
        let argn = incoming_args(ir);
        let ret_imm = false;
        let ret_plain = false;
        let ok = argn <= 512 && stack_need(ir) <= 2048;
        let at = 0;
        while (at < len(ir) && ok) {
            let f = ir[at];
            if (f == insn.IR_LABEL) {
                note_label(labs, lpos, ir[at + 1], len(code) / 8);
            } else if (f == insn.IR_LOC) {
            } else if (f == insn.IR_TEXT) {
                let ti = ir[at + 1];
                if (ti < 0 || ti >= len(txt) || !is_comment(txt[ti])) {
                    ok = false;
                };
            } else if (f == insn.F_MOV_I_R && ir[at + 3] == 64
                && ir[at + 2] != insn.R_RSP) {
                code = push8(code, enc(S_MOV_I_R), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_MOV_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_MOV_R_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if ((f == insn.F_MOV_R_D || f == insn.F_MOV_R_P
                || f == insn.F_MOV_R_0 || f == insn.F_MOV_R_M)
                && ir[at + 2] == 64) {
                // mov REG, MEM: a store
                code += enc(S_STORE);
                code += slot(ir[at + 1]);
                code = emit_mem(code, ir, at + 3, mlabs,
                    f == insn.F_MOV_R_0);
                code += 0;
            } else if ((f == insn.F_MOV_D_R || f == insn.F_MOV_P_R
                || f == insn.F_MOV_0_R || f == insn.F_MOV_M_R)
                && ir[at + 7] == 64) {
                // mov MEM, REG: a load
                code += enc(S_LOAD);
                code += slot(ir[at + 6]);
                code = emit_mem(code, ir, at + 1, mlabs,
                    f == insn.F_MOV_0_R);
                code += 0;
            } else if (f == insn.F_MOV_I_D || f == insn.F_MOV_I_0
                || f == insn.F_MOV_I_M) {
                code += enc(S_STORE_I);
                code += ir[at + 1];
                code = emit_mem(code, ir, at + 2, mlabs,
                    f == insn.F_MOV_I_0);
                code += 0;
            } else if ((f == insn.F_LEA_D_R || f == insn.F_LEA_M_R
                || f == insn.F_LEA_P_R) && ir[at + 7] == 64) {
                code += enc(S_LEA);
                code += slot(ir[at + 6]);
                code = emit_mem(code, ir, at + 1, mlabs, false);
                code += 0;
            } else if (f == insn.F_ADD_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_ADD_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_ADD_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_ADD_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_SUB_I_R && ir[at + 3] == 64) {
                if (ir[at + 2] == insn.R_RSP && ir[at + 1] > MAX_FRAME) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_SUB_I), ir[at + 1],
                        slot(ir[at + 2]), 0, 0, 0, 0, 0);
                };
            } else if (f == insn.F_SUB_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_SUB_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_XOR_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_XOR_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_XOR_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_XOR_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_AND_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_AND_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_AND_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_AND_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_OR_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_OR_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_OR_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_OR_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_CMP_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_CMP_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_CMP_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_CMP_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_TEST_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_TEST_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_TEST_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_TEST_R), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_IMUL_R_R && ir[at + 2] == 64
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_IMUL), slot(ir[at + 3]),
                    slot(ir[at + 1]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_SHL_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_SHL_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_SAR_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_SAR_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_SHR_I_R && ir[at + 3] == 64) {
                code = push8(code, enc(S_SHR_I), ir[at + 1],
                    slot(ir[at + 2]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_NEG_R && ir[at + 2] == 64) {
                code = push8(code, enc(S_NEG), slot(ir[at + 1]), 0, 0, 0,
                    0, 0, 0);
            } else if (f == insn.F_NOT_R && ir[at + 2] == 64) {
                code = push8(code, enc(S_NOT), slot(ir[at + 1]), 0, 0, 0,
                    0, 0, 0);
            } else if (f == insn.F_PUSH_R && ir[at + 2] == 64) {
                code = push8(code, enc(S_PUSH_R), slot(ir[at + 1]), 0, 0,
                    0, 0, 0, 0);
            } else if (f == insn.F_POP_R && ir[at + 2] == 64) {
                code = push8(code, enc(S_POP_R), slot(ir[at + 1]), 0, 0,
                    0, 0, 0, 0);
            } else if (f == insn.F_CALL_L && !wintgt.target_is_aarch64()) {
                // A Y-level call: its arguments are already on the virtual
                // stack, so the interpreter copies that window to the real
                // stack and calls the label. Runtime helpers that take
                // register arguments are left to the native static pass.
                let nm = lbl.lname(ir[at + 1]);
                if (nm[:4] != "yfn_") {
                    ok = false;
                } else {
                    let li = mem_label(mlabs, ir[at + 1]);
                    if (li < 0) {
                        mlabs += ir[at + 1];
                        li = len(mlabs) - 1;
                    };
                    code = push8(code, enc(S_CALL), li, 0, 0, 0, 0, 0, 0);
                };
            } else if (is_setcc_ir(f)) {
                code = push8(code, enc(setcc_sem(f)), slot(ir[at + 1]),
                    0, 0, 0, 0, 0, 0);
            } else if (f == insn.F_MOVZBQ_R_R && ir[at + 2] == 8
                && ir[at + 4] == 64) {
                code = push8(code, enc(S_MOVZBQ), slot(ir[at + 1]),
                    slot(ir[at + 3]), 0, 0, 0, 0, 0);
            } else if (f == insn.F_JMP_L) {
                code = push8(code, enc(S_JMP), 0, 0, 0, 0, 0, 0, 0);
                brword += len(code) - 7;
                brlab += ir[at + 1];
            } else if (f == insn.F_JE_L || f == insn.F_JNE_L
                || f == insn.F_JZ_L || f == insn.F_JNZ_L
                || f == insn.F_JS_L || f == insn.F_JNS_L
                || f == insn.F_JL_L || f == insn.F_JGE_L
                || f == insn.F_JLE_L || f == insn.F_JG_L
                || f == insn.F_JB_L || f == insn.F_JAE_L
                || f == insn.F_JBE_L || f == insn.F_JA_L
                || f == insn.F_JP_L || f == insn.F_JNP_L) {
                let sem = jcc_sem(f);
                code = push8(code, enc(sem), 0, 0, 0, 0, 0, 0, 0);
                brword += len(code) - 7;
                brlab += ir[at + 1];
            } else if (f == insn.F_MOVSD_R_R && ir[at + 2] == 128
                && ir[at + 4] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_XMOV), xslot(ir[at + 1]),
                        xslot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if ((f == insn.F_MOVSD_D_R || f == insn.F_MOVSD_0_R)
                && ir[at + 7] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code += enc(S_XLOAD);
                    code += xslot(ir[at + 6]);
                    code = emit_mem(code, ir, at + 1, mlabs,
                        f == insn.F_MOVSD_0_R);
                    code += 0;
                };
            } else if ((f == insn.F_MOVSD_R_D || f == insn.F_MOVSD_R_0)
                && ir[at + 2] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code += enc(S_XSTORE);
                    code += xslot(ir[at + 1]);
                    code = emit_mem(code, ir, at + 3, mlabs,
                        f == insn.F_MOVSD_R_0);
                    code += 0;
                };
            } else if ((f == insn.F_ADDSD_R_R || f == insn.F_SUBSD_R_R
                || f == insn.F_MULSD_R_R || f == insn.F_DIVSD_R_R)
                && ir[at + 2] == 128 && ir[at + 4] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    let xsem = S_XADD;
                    if (f == insn.F_SUBSD_R_R) { xsem = S_XSUB; }
                    else if (f == insn.F_MULSD_R_R) { xsem = S_XMUL; }
                    else if (f == insn.F_DIVSD_R_R) { xsem = S_XDIV; };
                    code = push8(code, enc(xsem), xslot(ir[at + 1]),
                        xslot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if ((f == insn.F_DIVSD_D_R || f == insn.F_DIVSD_0_R)
                && ir[at + 7] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code += enc(S_XDIVM);
                    code += xslot(ir[at + 6]);
                    code = emit_mem(code, ir, at + 1, mlabs,
                        f == insn.F_DIVSD_0_R);
                    code += 0;
                };
            } else if (f == insn.F_UCOMISD_R_R && ir[at + 2] == 128
                && ir[at + 4] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_XUCOMI), xslot(ir[at + 1]),
                        xslot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if ((f == insn.F_UCOMISD_D_R || f == insn.F_UCOMISD_0_R)
                && ir[at + 7] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code += enc(S_XUCOMIM);
                    code += xslot(ir[at + 6]);
                    code = emit_mem(code, ir, at + 1, mlabs,
                        f == insn.F_UCOMISD_0_R);
                    code += 0;
                };
            } else if (f == insn.F_CVTSI2SD_R_R && ir[at + 2] == 64
                && ir[at + 4] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_XCVTSI), slot(ir[at + 1]),
                        xslot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if (f == insn.F_CVTTSD2SI_R_R && ir[at + 2] == 128
                && ir[at + 4] == 64) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_XCVTTSI), xslot(ir[at + 1]),
                        slot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if (f == insn.F_SQRTSD_R_R && ir[at + 2] == 128
                && ir[at + 4] == 128) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(S_XSQRT), xslot(ir[at + 1]),
                        xslot(ir[at + 3]), 0, 0, 0, 0, 0);
                };
            } else if (f == insn.F_MOVQ_R_R
                && ((ir[at + 2] == 128 && ir[at + 4] == 64)
                    || (ir[at + 2] == 64 && ir[at + 4] == 128))) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    let r1 = if (ir[at + 2] == 128) { xslot(ir[at + 1]) } else { slot(ir[at + 1]) };
                    let r2 = if (ir[at + 4] == 128) { xslot(ir[at + 3]) } else { slot(ir[at + 3]) };
                    code = push8(code, enc(S_MOVQ), r1, ir[at + 2],
                        r2, ir[at + 4], 0, 0, 0);
                };
            } else if ((f == insn.F_MOVZBQ_D_R || f == insn.F_MOVZBQ_0_R
                || f == insn.F_MOVZBQ_M_R) && ir[at + 7] == 64) {
                code += enc(S_MOVZBQ_M);
                code += slot(ir[at + 6]);
                code = emit_mem(code, ir, at + 1, mlabs,
                    f == insn.F_MOVZBQ_0_R);
                code += 0;
            } else if (f == insn.F_CQO) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code += enc(S_CQO);
                };
            } else if ((f == insn.F_IDIV_R || f == insn.F_DIV_R)
                && ir[at + 2] == 64) {
                if (wintgt.target_is_aarch64()) {
                    ok = false;
                } else {
                    code = push8(code, enc(if (f == insn.F_IDIV_R) { S_IDIV } else { S_DIV }),
                        slot(ir[at + 1]), 0, 0, 0, 0, 0, 0);
                };
            } else if (f == insn.F_RET_I || f == insn.F_RET) {
                if (f == insn.F_RET_I) {
                    let rn = ret_n(f, ir, at);
                    if (ret_plain || argn > rn) { ok = false; };
                    ret_imm = true;
                    if (n < 0) { n = rn; } else if (n != rn) { ok = false; };
                } else {
                    if (ret_imm || argn != n && n >= 0) { ok = false; };
                    ret_plain = true;
                    n = argn;
                };
                code = push8(code, enc(S_RET), 0, 0, 0, 0, 0, 0, 0);
            } else {
                ok = false;
            };
            at += insn.IR_W;
        };
        // The copied arguments grow up from VRS_OFF and the label table grows
        // down from CTX_OFF; keep them apart.
        if (n + len(mlabs) > 900) { ok = false; };
        if (!ok || n < 0 || len(code) == 0 || len(mlabs) > MAX_LABELS) {
            fail_res()
        } else {
            let bad = false;
            let count = len(code) / 8;
            for i in 0..len(brword) {
                let p = find_pos(labs, lpos, brlab[i]);
                if (p < 0 || p >= count) {
                    bad = true;
                } else {
                    code[brword[i]] = p * 64;
                };
            };
            if (bad) {
                fail_res()
            } else {
                { ok: true, code: code, labs: labs, lpos: lpos,
                    mlabs: mlabs, n: n, ret_imm: ret_imm }
            }
        }
    }
};

def setcc_sem(f: long) -> long {
    if (f == insn.F_SETE_R) { S_SETE }
    else if (f == insn.F_SETNE_R) { S_SETNE }
    else if (f == insn.F_SETL_R) { S_SETL }
    else if (f == insn.F_SETG_R) { S_SETG }
    else if (f == insn.F_SETGE_R) { S_SETGE }
    else if (f == insn.F_SETLE_R) { S_SETLE }
    else if (f == insn.F_SETA_R) { S_SETA }
    else if (f == insn.F_SETAE_R) { S_SETAE }
    else if (f == insn.F_SETP_R) { S_SETP }
    else { S_SETNP }
};

def is_setcc_ir(f: long) -> bool {
    f == insn.F_SETE_R || f == insn.F_SETNE_R || f == insn.F_SETL_R
        || f == insn.F_SETG_R || f == insn.F_SETGE_R || f == insn.F_SETLE_R
        || f == insn.F_SETA_R || f == insn.F_SETAE_R
        || f == insn.F_SETP_R || f == insn.F_SETNP_R
};

def jcc_sem(f: long) -> long {
    if (f == insn.F_JE_L) { S_JE }
    else if (f == insn.F_JNE_L) { S_JNE }
    else if (f == insn.F_JZ_L) { S_JZ }
    else if (f == insn.F_JNZ_L) { S_JNZ }
    else if (f == insn.F_JS_L) { S_JS }
    else if (f == insn.F_JNS_L) { S_JNS }
    else if (f == insn.F_JL_L) { S_JL }
    else if (f == insn.F_JGE_L) { S_JGE }
    else if (f == insn.F_JLE_L) { S_JLE }
    else if (f == insn.F_JG_L) { S_JG }
    else if (f == insn.F_JB_L) { S_JB }
    else if (f == insn.F_JAE_L) { S_JAE }
    else if (f == insn.F_JBE_L) { S_JBE }
    else if (f == insn.F_JA_L) { S_JA }
    else if (f == insn.F_JP_L) { S_JP }
    else { S_JNP }
};

// ── the wrapper ─────────────────────────────────────────────────────────

def lea_d(o: [long], base: long, disp: long, reg: long) -> [long] {
    push8(o, insn.F_LEA_D_R, base, -1, 1, disp, -1, reg, 64)
};

def lea_p(o: [long], label: long, reg: long) -> [long] {
    push8(o, insn.F_LEA_P_R, -1, -1, 1, 0, label, reg, 64)
};

def mov_d(o: [long], base: long, disp: long, reg: long) -> [long] {
    push8(o, insn.F_MOV_R_D, reg, 64, base, -1, 1, disp, -1)
};

def mov_r_d(o: [long], reg: long, base: long, disp: long) -> [long] {
    push8(o, insn.F_MOV_D_R, base, -1, 1, disp, -1, reg, 64)
};

def mov_i_d(o: [long], v: long, base: long, disp: long) -> [long] {
    push8(o, insn.F_MOV_I_D, v, base, -1, 1, disp, -1, 0)
};

def vreg_disp(sl: long) -> long { CTX_OFF + CTX_VREG + 8 * sl };

def wrapper(original: long, n: long, code_label: long,
        mlabs: [long], ret_imm: bool, fk: long, map_label: long) -> [long] {
    let table_off = CTX_OFF - 8 * len(mlabs);
    let o: [long] = [];
    o = push8(o, insn.IR_LABEL, original, 0, 0, 0, 0, 0, 0);
    o = push8(o, insn.F_PUSH_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    o = push8(o, insn.F_MOV_R_R, insn.R_RSP, 64, insn.R_RBP, 64, 0, 0, 0);
    o = push8(o, insn.F_SUB_I_R, VM_AREA, insn.R_RSP, 64, 0, 0, 0, 0);
    for sl in 0..16 { o = mov_i_d(o, 0, insn.R_RBP, vreg_disp(sl)); };
    o = lea_d(o, insn.R_RBP, VRS_OFF, insn.R_RAX);
    o = mov_d(o, insn.R_RBP, vreg_disp(slot(insn.R_RSP)), insn.R_RAX);
    o = lea_p(o, code_label, insn.R_RAX);
    o = mov_d(o, insn.R_RBP, CTX_OFF + CTX_CODE, insn.R_RAX);
    if (len(mlabs) == 0) {
        o = mov_i_d(o, 0, insn.R_RBP, CTX_OFF + CTX_LABELS);
    } else {
        o = lea_d(o, insn.R_RBP, table_off, insn.R_RAX);
        o = mov_d(o, insn.R_RBP, CTX_OFF + CTX_LABELS, insn.R_RAX);
    };
    o = mov_i_d(o, 0, insn.R_RBP, CTX_OFF + CTX_PC);
    o = push8(o, insn.F_MOV_I_R, fk, insn.R_RAX, 64, 0, 0, 0, 0);
    o = mov_d(o, insn.R_RBP, CTX_OFF + CTX_KEY, insn.R_RAX);
    if (vm_high) {
        o = lea_p(o, map_label, insn.R_RAX);
        o = mov_d(o, insn.R_RBP, CTX_OFF + CTX_MAP, insn.R_RAX);
    };
    for fl in 0..5 {
        o = mov_i_d(o, 0, insn.R_RBP, CTX_OFF + CTX_FLAGS + 8 * fl);
    };
    for i in 0..len(mlabs) {
        o = lea_p(o, mlabs[i], insn.R_RAX);
        o = lea_d(o, insn.R_RBP, table_off + 8 * i, insn.R_RDX);
        o = mov_d(o, insn.R_RDX, 0, insn.R_RAX);
    };
    for k in 0..n {
        o = mov_r_d(o, insn.R_RAX, insn.R_RBP, 16 + 8 * k);
        o = mov_d(o, insn.R_RBP, VRS_OFF + 8 + 8 * k, insn.R_RAX);
    };
    o = lea_d(o, insn.R_RBP, CTX_OFF, insn.R_RDI);
    o = push8(o, insn.F_CALL_L, vm_interp, 0, 0, 0, 0, 0, 0);
    o = mov_r_d(o, insn.R_RAX, insn.R_RBP, vreg_disp(slot(insn.R_RAX)));
    o = push8(o, insn.F_MOV_R_R, insn.R_RBP, 64, insn.R_RSP, 64, 0, 0, 0);
    o = push8(o, insn.F_POP_R, insn.R_RBP, 64, 0, 0, 0, 0, 0);
    if (ret_imm) {
        push8(o, insn.F_RET_I, 8 * n, 0, 0, 0, 0, 0, 0)
    } else {
        push8(o, insn.F_RET, 0, 0, 0, 0, 0, 0, 0)
    }
};

def map_text(label: long) -> str {
    let tab: [long] = [];
    for i in 0..256 { tab += 0; };
    for s in 0..S_COUNT { tab[opcode(vm_fperm[s])] = opcode(s); };
    let out = ".section .rodata\n" + lbl.lname(label) + ":\n";
    let at = 0;
    while (at < 256) {
        let line = "    .byte ";
        let j = 0;
        while (j < 16) {
            if (j > 0) { line += ","; };
            line += tostring(tab[at + j]);
            j += 1;
        };
        out += line + "\n";
        at += 16;
    };
    out
};

def code_text(label: long, code: [long], fk: long) -> str {
    let out = ".section .rodata\n" + lbl.lname(label) + ":\n";
    let at = 0;
    while (at < len(code)) {
        let base = at - at % 8;
        let key = vm_mix64(fk + base);
        let line = "    .byte ";
        let j = 0;
        while (j < 16) {
            let w = code[at + j / 8] ^ key;
            let b = (w >>> (8 * (j % 8))) & 255;
            if (j > 0) { line += ","; };
            line += tostring(b);
            j += 1;
        };
        out += line + "\n";
        at += 2;
    };
    out
};

def compile(ir: [long], txt: [str], name: str) -> VmFn {
    if (name == "_start" || name[:2] == "y_") {
        { ok: false, ir: [], ro: "", n: 0, ret_imm: false }
    } else {
        let t = translate(ir, txt);
        if (!t.ok) {
            { ok: false, ir: [], ro: "", n: 0, ret_imm: false }
        } else {
            let original = ir[1];
            let code_label = lbl.lbl_fresh("yvmx_code_" + tostring(vm_bc_count + 1));
            let fk = vm_mix64(vm_seed + vm_bc_count * 0x9E3779B97F4A7C15) | 1;
            let map_label = lbl.lbl_fresh("yvmx_map_" + tostring(vm_bc_count + 1));
            let w = wrapper(original, t.n, code_label, t.mlabs, t.ret_imm, fk,
                map_label);
            vm_used = true;
            vm_bc_count += 1;
            obf.note_vm_bc();
            let ro = code_text(code_label, t.code, fk);
            if (vm_high) { ro += map_text(map_label); };
            { ok: true, ir: w, ro: ro, n: t.n, ret_imm: t.ret_imm }
        }
    }
};

// ── the interpreter text ────────────────────────────────────────────────

def ih(sem: long) -> str {
    lbl.lname(vm_interp) + "_h" + tostring(sem)
};

def idisp() -> str { lbl.lname(vm_interp) + "_disp" };
def iepi() -> str { lbl.lname(vm_interp) + "_epi" };
def ibad() -> str { lbl.lname(vm_interp) + "_bad" };

def adv() -> str {
    "    add $64, 0(%rbx)\n    jmp " + idisp() + "\n"
};

// vm_mix64 in the interpreter: the same splitmix finalizer as the build, so a
// bytecode word decodes to exactly what code_text wrote.
def mix64_text(reg: str) -> str {
    "    mov $" + tostring(0x9E3779B97F4A7C15) + ", %r9\n" +
    "    add %r9, " + reg + "\n" +
    "    mov " + reg + ", %r9\n" +
    "    shr $30, %r9\n" +
    "    xor %r9, " + reg + "\n" +
    "    mov $" + tostring(0xBF58476D1CE4E5B9) + ", %r9\n" +
    "    imul %r9, " + reg + "\n" +
    "    mov " + reg + ", %r9\n" +
    "    shr $27, %r9\n" +
    "    xor %r9, " + reg + "\n" +
    "    mov $" + tostring(0x94D049BB133111EB) + ", %r9\n" +
    "    imul %r9, " + reg + "\n" +
    "    mov " + reg + ", %r9\n" +
    "    shr $31, %r9\n" +
    "    xor %r9, " + reg + "\n"
};

def cap() -> str {
    "    setb %al\n    movzbq %al, %rax\n    mov %rax, 24(%rbx)\n" +
    "    sete %al\n    movzbq %al, %rax\n    mov %rax, 32(%rbx)\n" +
    "    sets %al\n    movzbq %al, %rax\n    mov %rax, 40(%rbx)\n" +
    "    seto %al\n    movzbq %al, %rax\n    mov %rax, 48(%rbx)\n" +
    "    setp %al\n    movzbq %al, %rax\n    mov %rax, 56(%rbx)\n"
};

def mem_addr(off: long) -> str {
    let nb = fresh_tmp();
    let ni = fresh_tmp();
    let nl = fresh_tmp();
    "    xor %r10, %r10\n" +
    "    mov " + tostring(off) + "(%r11), %rax\n" +
    "    cmp $-1, %rax\n    je " + nb + "\n" +
    "    mov 64(%rbx,%rax,8), %r10\n" + nb + ":\n" +
    "    mov " + tostring(off + 8) + "(%r11), %rax\n" +
    "    cmp $-1, %rax\n    je " + ni + "\n" +
    "    mov 64(%rbx,%rax,8), %rdx\n" +
    "    mov " + tostring(off + 16) + "(%r11), %rcx\n" +
    "    shl %cl, %rdx\n    add %rdx, %r10\n" + ni + ":\n" +
    "    mov " + tostring(off + 24) + "(%r11), %rax\n" +
    "    add %rax, %r10\n" +
    "    mov " + tostring(off + 32) + "(%r11), %rax\n" +
    "    cmp $-1, %rax\n    je " + nl + "\n" +
    "    mov 16(%rbx), %rcx\n" +
    "    mov (%rcx,%rax,8), %rcx\n    add %rcx, %r10\n" + nl + ":\n"
};

def store_slot(off: long) -> str {
    "    mov " + tostring(off) + "(%r11), %rcx\n" +
    "    mov %rax, 64(%rbx,%rcx,8)\n"
};

def load_slot(off: long, reg: str) -> str {
    "    mov " + tostring(off) + "(%r11), %rcx\n" +
    "    mov 64(%rbx,%rcx,8), " + reg + "\n"
};

def load_slot2(off: long, reg: str) -> str {
    "    mov " + tostring(off) + "(%r11), %rcx\n" +
    "    mov 64(%rbx,%rcx,8), " + reg + "\n"
};

def xload_slot(off: long, xmm: str) -> str {
    "    mov " + tostring(off) + "(%r11), %rcx\n" +
    "    movsd " + tostring(CTX_XMM) + "(%rbx,%rcx,8), " + xmm + "\n"
};

def xstore_slot(off: long, xmm: str) -> str {
    "    mov " + tostring(off) + "(%r11), %rcx\n" +
    "    movsd " + xmm + ", " + tostring(CTX_XMM) + "(%rbx,%rcx,8)\n"
};

// ucomisd leaves CF, ZF and PF meaningful; SF and OF are defined zero. The
// setcc handlers read these cells, so copy all five.
def xflags() -> str {
    "    setb %al\n    movzbq %al, %rcx\n    mov %rcx, " + tostring(CTX_FLAGS) + "(%rbx)\n" +
    "    sete %al\n    movzbq %al, %rcx\n    mov %rcx, " + tostring(CTX_FLAGS + 8) + "(%rbx)\n" +
    "    setp %al\n    movzbq %al, %rcx\n    mov %rcx, " + tostring(CTX_FLAGS + 32) + "(%rbx)\n" +
    "    xor %eax, %eax\n    mov %rax, " + tostring(CTX_FLAGS + 16) + "(%rbx)\n" +
    "    mov %rax, " + tostring(CTX_FLAGS + 24) + "(%rbx)\n"
};

def alu_handler(sem: long, mn: str, store: bool) -> str {
    let h = ih(sem);
    let out = h + ":\n";
    out += load_slot(16, "%rax");
    out += "    mov 8(%r11), %rdx\n";
    out += "    " + mn + " %rdx, %rax\n";
    if (store) { out += store_slot(16); };
    out += cap();
    out += adv();
    out
};

def alu_r_handler(sem: long, mn: str, store: bool) -> str {
    let h = ih(sem);
    let out = h + ":\n";
    out += load_slot(8, "%rax");
    out += load_slot2(16, "%rdx");
    out += "    " + mn + " %rdx, %rax\n";
    if (store) { out += store_slot(8); };
    out += cap();
    out += adv();
    out
};

def shift_handler(sem: long, mn: str) -> str {
    let h = ih(sem);
    let out = h + ":\n";
    out += load_slot(16, "%rax");
    out += "    mov 8(%r11), %rcx\n";
    out += "    " + mn + " %cl, %rax\n";
    out += store_slot(16);
    out += cap();
    out += adv();
    out
};

def unary_handler(sem: long, mn: str) -> str {
    let h = ih(sem);
    let out = h + ":\n";
    out += load_slot(8, "%rax");
    out += "    " + mn + " %rax\n";
    out += store_slot(8);
    out += cap();
    out += adv();
    out
};

def jcc_taken(sem: long, t: str) -> str {
    let out = "";
    let f = "";   // flag cell offset
    if (sem == S_JE || sem == S_JZ) { f = "32"; }
    else if (sem == S_JNE || sem == S_JNZ) { f = "32"; }
    else if (sem == S_JS) { f = "40"; }
    else if (sem == S_JNS) { f = "40"; }
    else if (sem == S_JB) { f = "24"; }
    else if (sem == S_JAE) { f = "24"; }
    else if (sem == S_JP) { f = "56"; }
    else if (sem == S_JNP) { f = "56"; };
    if (sem == S_JNE || sem == S_JNZ || sem == S_JNS || sem == S_JAE
        || sem == S_JNP) {
        out += "    mov " + f + "(%rbx), %rax\n    test %rax, %rax\n    je " + t + "\n";
    } else if (sem == S_JBE) {
        out += "    mov 24(%rbx), %rax\n    test %rax, %rax\n    jne " + t + "\n";
        out += "    mov 32(%rbx), %rax\n    test %rax, %rax\n    jne " + t + "\n";
    } else if (sem == S_JA) {
        let advl = fresh_tmp();
        out += "    mov 24(%rbx), %rax\n    test %rax, %rax\n    jne " + advl + "\n";
        out += "    mov 32(%rbx), %rax\n    test %rax, %rax\n    jne " + advl + "\n";
        out += "    jmp " + t + "\n" + advl + ":\n";
    } else if (sem == S_JL || sem == S_JGE) {
        out += "    mov 40(%rbx), %rax\n    mov 48(%rbx), %rcx\n    cmp %rcx, %rax\n";
        if (sem == S_JL) { out += "    jne " + t + "\n"; } else { out += "    je " + t + "\n"; };
    } else if (sem == S_JLE) {
        out += "    mov 32(%rbx), %rax\n    test %rax, %rax\n    jne " + t + "\n";
        out += "    mov 40(%rbx), %rax\n    mov 48(%rbx), %rcx\n    cmp %rcx, %rax\n    jne " + t + "\n";
    } else if (sem == S_JG) {
        let advl = fresh_tmp();
        out += "    mov 32(%rbx), %rax\n    test %rax, %rax\n    jne " + advl + "\n";
        out += "    mov 40(%rbx), %rax\n    mov 48(%rbx), %rcx\n    cmp %rcx, %rax\n    je " + t + "\n";
        out += "    jmp " + advl + "\n" + advl + ":\n";
    } else {
        out += "    mov " + f + "(%rbx), %rax\n    test %rax, %rax\n    jne " + t + "\n";
    };
    out
};

def jcc_handler(sem: long) -> str {
    let h = ih(sem);
    let t = fresh_tmp();
    let a = fresh_tmp();
    let out = h + ":\n";
    out += jcc_taken(sem, t);
    out += "    jmp " + a + "\n";
    out += t + ":\n";
    out += "    mov 8(%r11), %rax\n    mov %rax, 0(%rbx)\n    jmp " + idisp() + "\n";
    out += a + ":\n" + adv();
    out
};

def setcc_handler(sem: long) -> str {
    let cc = "mov 32(%rbx), %rdx\n"; // ZF
    if (sem == S_SETNE) { cc = "mov 32(%rbx), %rdx\n    xor $1, %rdx\n"; }
    else if (sem == S_SETL) { cc = "mov 40(%rbx), %rdx\n    mov 48(%rbx), %r9\n    xor %r9, %rdx\n"; }
    else if (sem == S_SETG) { cc = "mov 40(%rbx), %rdx\n    mov 48(%rbx), %r9\n    xor %r9, %rdx\n    mov 32(%rbx), %r9\n    xor %r9, %rdx\n    xor $1, %rdx\n"; }
    else if (sem == S_SETGE) { cc = "mov 40(%rbx), %rdx\n    mov 48(%rbx), %r9\n    xor %r9, %rdx\n    xor $1, %rdx\n"; }
    else if (sem == S_SETLE) { cc = "mov 40(%rbx), %rdx\n    mov 48(%rbx), %r9\n    xor %r9, %rdx\n    mov 32(%rbx), %r9\n    or %r9, %rdx\n"; }
    else if (sem == S_SETA) { cc = "mov 24(%rbx), %rdx\n    mov 32(%rbx), %r9\n    or %r9, %rdx\n    xor $1, %rdx\n"; }
    else if (sem == S_SETAE) { cc = "mov 24(%rbx), %rdx\n    xor $1, %rdx\n"; }
    else if (sem == S_SETB) { cc = "mov 24(%rbx), %rdx\n"; }
    else if (sem == S_SETBE) { cc = "mov 24(%rbx), %rdx\n    mov 32(%rbx), %r9\n    or %r9, %rdx\n"; }
    else if (sem == S_SETP) { cc = "mov 56(%rbx), %rdx\n"; }
    else if (sem == S_SETNP) { cc = "mov 56(%rbx), %rdx\n    xor $1, %rdx\n"; };
    ih(sem) + ":\n" +
    "    mov 8(%r11), %rcx\n" +
    "    mov 64(%rbx,%rcx,8), %rax\n" +
    "    and $-256, %rax\n" +
    "    " + cc +
    "    and $1, %rdx\n" +
    "    or %rdx, %rax\n" +
    "    mov %rax, 64(%rbx,%rcx,8)\n" +
    adv()
};

def handler(sem: long) -> str {
    if (sem == S_MOV_I_R) {
        ih(sem) + ":\n    mov 8(%r11), %rax\n    mov 16(%r11), %rcx\n    mov %rax, 64(%rbx,%rcx,8)\n" + adv()
    } else if (sem == S_MOV_R_R) {
        ih(sem) + ":\n    mov 8(%r11), %rax\n    mov 16(%r11), %rcx\n    mov 64(%rbx,%rcx,8), %rdx\n    mov %rdx, 64(%rbx,%rax,8)\n" + adv()
    } else if (sem == S_LOAD) {
        ih(sem) + ":\n" + mem_addr(16) + "    mov 8(%r11), %rcx\n    mov (%r10), %rax\n    mov %rax, 64(%rbx,%rcx,8)\n" + adv()
    } else if (sem == S_STORE) {
        ih(sem) + ":\n" + mem_addr(16) + "    mov 8(%r11), %rcx\n    mov 64(%rbx,%rcx,8), %rax\n    mov %rax, (%r10)\n" + adv()
    } else if (sem == S_STORE_I) {
        ih(sem) + ":\n" + mem_addr(16) + "    mov 8(%r11), %rax\n    mov %rax, (%r10)\n" + adv()
    } else if (sem == S_LEA) {
        ih(sem) + ":\n" + mem_addr(16) + "    mov 8(%r11), %rcx\n    mov %r10, 64(%rbx,%rcx,8)\n" + adv()
    } else if (sem == S_ADD_I) {
        alu_handler(sem, "add", true)
    } else if (sem == S_ADD_R) {
        alu_r_handler(sem, "add", true)
    } else if (sem == S_SUB_I) {
        alu_handler(sem, "sub", true)
    } else if (sem == S_SUB_R) {
        alu_r_handler(sem, "sub", true)
    } else if (sem == S_XOR_I) {
        alu_handler(sem, "xor", true)
    } else if (sem == S_XOR_R) {
        alu_r_handler(sem, "xor", true)
    } else if (sem == S_AND_I) {
        alu_handler(sem, "and", true)
    } else if (sem == S_AND_R) {
        alu_r_handler(sem, "and", true)
    } else if (sem == S_OR_I) {
        alu_handler(sem, "or", true)
    } else if (sem == S_OR_R) {
        alu_r_handler(sem, "or", true)
    } else if (sem == S_CMP_I) {
        alu_handler(sem, "cmp", false)
    } else if (sem == S_CMP_R) {
        alu_r_handler(sem, "cmp", false)
    } else if (sem == S_TEST_I) {
        alu_handler(sem, "test", false)
    } else if (sem == S_TEST_R) {
        alu_r_handler(sem, "test", false)
    } else if (sem == S_IMUL) {
        alu_r_handler(sem, "imul", true)
    } else if (sem == S_SHL_I) {
        shift_handler(sem, "shl")
    } else if (sem == S_SAR_I) {
        shift_handler(sem, "sar")
    } else if (sem == S_SHR_I) {
        shift_handler(sem, "shr")
    } else if (sem == S_NEG) {
        unary_handler(sem, "neg")
    } else if (sem == S_NOT) {
        unary_handler(sem, "not")
    } else if (sem == S_PUSH_R) {
        ih(sem) + ":\n" + load_slot(8, "%rax") +
        "    mov " + tostring(64 + 8 * slot(insn.R_RSP)) + "(%rbx), %rcx\n" +
        "    sub $8, %rcx\n    mov %rcx, " + tostring(64 + 8 * slot(insn.R_RSP)) + "(%rbx)\n" +
        "    mov %rax, (%rcx)\n" + adv()
    } else if (sem == S_POP_R) {
        ih(sem) + ":\n" +
        "    mov " + tostring(64 + 8 * slot(insn.R_RSP)) + "(%rbx), %rcx\n" +
        "    mov (%rcx), %rax\n    add $8, %rcx\n" +
        "    mov %rcx, " + tostring(64 + 8 * slot(insn.R_RSP)) + "(%rbx)\n" +
        store_slot(8) + adv()
    } else if (sem == S_CALL) {
        let cp = ih(sem) + "_cp";
        let vrsp = tostring(64 + 8 * slot(insn.R_RSP));
        let vrax = tostring(64 + 8 * slot(insn.R_RAX));
        ih(sem) + ":\n" +
        "    mov 8(%r11), %rax\n" +
        "    mov 16(%rbx), %r13\n" +
        "    mov (%r13,%rax,8), %r13\n" +
        "    mov " + vrsp + "(%rbx), %r14\n" +
        "    mov %rsp, %r15\n" +
        "    sub $576, %rsp\n" +
        "    and $-16, %rsp\n" +
        "    mov %rsp, %r12\n" +
        "    xor %rcx, %rcx\n" +
        cp + ":\n" +
        "    mov (%r14,%rcx,8), %rax\n" +
        "    mov %rax, (%rsp,%rcx,8)\n" +
        "    add $1, %rcx\n" +
        "    cmp $64, %rcx\n" +
        "    jb " + cp + "\n" +
        "    call *%r13\n" +
        "    mov %rsp, %rcx\n" +
        "    sub %r12, %rcx\n" +
        "    mov %r15, %rsp\n" +
        "    mov " + vrsp + "(%rbx), %rdx\n" +
        "    add %rcx, %rdx\n" +
        "    mov %rdx, " + vrsp + "(%rbx)\n" +
        "    mov %rax, " + vrax + "(%rbx)\n" +
        "    xor %rax, %rax\n" +
        "    mov %rax, 24(%rbx)\n" +
        "    mov %rax, 32(%rbx)\n" +
        "    mov %rax, 40(%rbx)\n" +
        "    mov %rax, 48(%rbx)\n" +
        "    mov %rax, 56(%rbx)\n" +
        adv()
    } else if (sem == S_JMP) {
        ih(sem) + ":\n    mov 8(%r11), %rax\n    mov %rax, 0(%rbx)\n    jmp " + idisp() + "\n"
    } else if (sem == S_RET) {
        ih(sem) + ":\n    jmp " + iepi() + "\n"
    } else if (sem == S_XMOV) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm1") + xload_slot(16, "%xmm0") +
        "    movsd %xmm1, %xmm0\n" + xstore_slot(16, "%xmm0") + adv()
    } else if (sem == S_XLOAD) {
        ih(sem) + ":\n" + mem_addr(16) +
        "    movsd (%r10), %xmm0\n" + xstore_slot(8, "%xmm0") + adv()
    } else if (sem == S_XSTORE) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm0") + mem_addr(16) +
        "    movsd %xmm0, (%r10)\n" + adv()
    } else if (sem == S_XADD || sem == S_XSUB || sem == S_XMUL
        || sem == S_XDIV) {
        let xm = "addsd";
        if (sem == S_XSUB) { xm = "subsd"; }
        else if (sem == S_XMUL) { xm = "mulsd"; }
        else if (sem == S_XDIV) { xm = "divsd"; };
        ih(sem) + ":\n" + xload_slot(8, "%xmm1") + xload_slot(16, "%xmm0") +
        "    " + xm + " %xmm1, %xmm0\n" + xstore_slot(16, "%xmm0") + adv()
    } else if (sem == S_XDIVM) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm0") + mem_addr(16) +
        "    divsd (%r10), %xmm0\n" + xstore_slot(8, "%xmm0") + adv()
    } else if (sem == S_XUCOMI) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm1") + xload_slot(16, "%xmm0") +
        "    ucomisd %xmm1, %xmm0\n" + xflags() + adv()
    } else if (sem == S_XUCOMIM) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm0") + mem_addr(16) +
        "    ucomisd (%r10), %xmm0\n" + xflags() + adv()
    } else if (sem == S_XCVTSI) {
        ih(sem) + ":\n" + load_slot(8, "%rax") +
        "    cvtsi2sd %rax, %xmm0\n" + xstore_slot(16, "%xmm0") + adv()
    } else if (sem == S_XCVTTSI) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm0") +
        "    cvttsd2si %xmm0, %rax\n" + store_slot(16) + adv()
    } else if (sem == S_XSQRT) {
        ih(sem) + ":\n" + xload_slot(8, "%xmm0") +
        "    sqrtsd %xmm0, %xmm0\n" + xstore_slot(16, "%xmm0") + adv()
    } else if (sem == S_MOVQ) {
        let gx = ih(sem) + "_gx";
        let done = ih(sem) + "_done";
        ih(sem) + ":\n" +
        "    mov 16(%r11), %rax\n    cmp $128, %rax\n    jne " + gx + "\n" +
        xload_slot(8, "%xmm0") + "    movq %xmm0, %rax\n" + store_slot(24) +
        "    jmp " + done + "\n" + gx + ":\n" +
        load_slot(8, "%rax") + "    movq %rax, %xmm0\n" + xstore_slot(24, "%xmm0") +
        done + ":\n" + adv()
    } else if (sem == S_MOVZBQ_M) {
        ih(sem) + ":\n" + mem_addr(16) +
        "    movzbq (%r10), %rax\n" + store_slot(8) + adv()
    } else if (sem == S_CQO) {
        ih(sem) + ":\n" +
        "    mov " + tostring(64 + 8 * slot(insn.R_RAX)) + "(%rbx), %rax\n" +
        "    cqo\n" +
        "    mov %rdx, " + tostring(64 + 8 * slot(insn.R_RDX)) + "(%rbx)\n" + adv()
    } else if (sem == S_IDIV || sem == S_DIV) {
        let dv = "idiv";
        if (sem == S_DIV) { dv = "div"; };
        ih(sem) + ":\n" + load_slot(8, "%rcx") +
        "    mov " + tostring(64 + 8 * slot(insn.R_RDX)) + "(%rbx), %rdx\n" +
        "    mov " + tostring(64 + 8 * slot(insn.R_RAX)) + "(%rbx), %rax\n" +
        "    " + dv + " %rcx\n" +
        "    mov %rax, " + tostring(64 + 8 * slot(insn.R_RAX)) + "(%rbx)\n" +
        "    mov %rdx, " + tostring(64 + 8 * slot(insn.R_RDX)) + "(%rbx)\n" + adv()
    } else if (sem >= S_SETE && sem <= S_SETNP) {
        setcc_handler(sem)
    } else if (sem == S_MOVZBQ) {
        ih(sem) + ":\n" +
        "    mov 8(%r11), %rcx\n" +
        "    mov 16(%r11), %rdx\n" +
        "    mov 64(%rbx,%rcx,8), %rax\n" +
        "    movzbq %al, %rax\n" +
        "    mov %rax, 64(%rbx,%rdx,8)\n" +
        adv()
    } else {
        jcc_handler(sem)
    }
};

def sem_order() -> [long] {
    let o: [long] = [];
    for i in 0..S_COUNT { o += i; };
    let i = S_COUNT - 1;
    while (i > 0) {
        let j = 1 + below(i);
        let t = o[i];
        o[i] = o[j];
        o[j] = t;
        i -= 1;
    };
    o
};

def interp_text() -> str {
    if (!vm_used) {
        ""
    } else {
        let p = lbl.lname(vm_interp);
        let out = ".text\n" + p + ":\n    push %rbx\n    push %r12\n    push %r13\n    push %r14\n    push %r15\n    mov %rdi, %rbx\n    jmp " + idisp() + "\n";
        out += idisp() + ":\n";
        out += "    mov 0(%rbx), %r10\n    mov 8(%rbx), %r11\n    add %r10, %r11\n";
        out += "    mov %r10, %rax\n    shr $3, %rax\n";
        out += "    mov " + tostring(CTX_KEY) + "(%rbx), %r9\n    add %r9, %rax\n";
        out += mix64_text("%rax") + "    mov %rax, %rdx\n";
        let dloop = idisp() + "_dl";
        out += "    xor %rcx, %rcx\n" + dloop + ":\n";
        out += "    mov (%r11,%rcx,8), %rax\n";
        out += "    xor %rdx, %rax\n";
        out += "    mov %rax, " + tostring(CTX_INSN) + "(%rbx,%rcx,8)\n";
        out += "    add $1, %rcx\n    cmp $8, %rcx\n    jb " + dloop + "\n";
        out += "    lea " + tostring(CTX_INSN) + "(%rbx), %r11\n";
        out += "    mov (%r11), %rax\n";
        if (vm_high) {
            out += "    mov " + tostring(CTX_MAP) + "(%rbx), %r10\n";
            out += "    movzbq (%r10,%rax), %rax\n";
        };
        // One indirect jump through a 256-entry table of handler addresses.
        // The opcode values and the handler order are per build, and the table
        // lives in .rodata (sealed and lazily decrypted like other literals),
        // so the dispatch chain is not a list of recognizable constants.
        let tab = idisp() + "_tab";
        out += "    lea " + tab + "(%rip), %r10\n";
        out += "    mov (%r10,%rax,8), %r10\n";
        out += "    jmp *%r10\n";
        let o = sem_order();
        for k in 0..S_COUNT { out += handler(o[k]); };
        out += iepi() + ":\n    pop %r15\n    pop %r14\n    pop %r13\n    pop %r12\n    pop %rbx\n    ret\n";
        out += ibad() + ":\n    jmp " + iepi() + "\n";
        let slots: [str] = [];
        for i in 0..256 { slots += ibad(); };
        for s in 0..S_COUNT { slots[opcode(s)] = ih(s); };
        out += ".section .rodata\n.align 8\n" + tab + ":\n";
        for i in 0..256 { out += ".quad " + slots[i] + "\n"; };
        out += ".text\n";
        out
    }
};

export { vm_begin, compile, used, compiled_count, interp_label, interp_text };
