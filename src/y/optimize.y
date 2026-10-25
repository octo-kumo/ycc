// Final-link optimizations; packed units and cached objects stay mode-neutral.
import insn from "./ir.y";

let optimize_goal = "speed";

def set_goal(goal: str) -> void { optimize_goal = goal; };
def goal() -> str { optimize_goal };

def next_code(body: [long], at: long) -> long {
    while (at < len(body) && body[at] == insn.IR_LOC) { at += insn.IR_W; };
    at
};

def is_branch(f: long) -> bool {
    f == insn.F_JMP_L || (f >= insn.F_JE_L && f <= insn.F_JNS_L)
        || f == insn.F_JAE_L || f == insn.F_JP_L || f == insn.F_JBE_L
        || f == insn.F_JA_L || f == insn.F_JNP_L
};

def terminates(f: long) -> bool {
    f == insn.F_JMP_L || f == insn.F_JMP_IND || f == insn.F_RET || f == insn.F_RET_I
};

// Branches to the next label and instructions following an unconditional
// transfer do no work. Labels and raw assembly are conservative barriers.
def cleanup(body: [long]) -> [long] {
    let wp = 0;
    let dead = false;
    let at = 0;
    while (at < len(body)) {
        let f = body[at];
        if (f == insn.IR_LABEL || f == insn.IR_TEXT) { dead = false; };
        let drop = dead && f != insn.IR_LOC;
        if (f == insn.F_MOV_R_R && body[at + 2] == 64 && body[at + 4] == 64
            && body[at + 1] == body[at + 3]) { drop = true; };
        if (!drop && is_branch(f)) {
            let p = next_code(body, at + insn.IR_W);
            while (p < len(body) && body[p] == insn.IR_LABEL) {
                if (body[p + 1] == body[at + 1]) { drop = true; };
                p = next_code(body, p + insn.IR_W);
            };
        };
        if (!drop) {
            if (wp != at) { for i in 0..insn.IR_W { body[wp + i] = body[at + i]; }; };
            wp += insn.IR_W;
        };
        if (terminates(f)) { dead = true; };
        at += insn.IR_W;
    };
    while (len(body) > wp) { body.pop(); };
    body
};

// A zero idiom is smaller and breaks a register dependency. Only use it
// when the very next instruction overwrites every arithmetic flag it sets.
def kills_flags(f: long) -> bool {
    f == insn.F_CMP_I_R || f == insn.F_CMP_R_R || f == insn.F_CMP_M_R
        || f == insn.F_TEST_R_R || f == insn.F_TEST_I_R
        || f == insn.F_ADD_I_R || f == insn.F_ADD_R_R
        || f == insn.F_SUB_I_R || f == insn.F_SUB_R_R
        || f == insn.F_AND_I_R || f == insn.F_AND_R_R
        || f == insn.F_OR_I_R || f == insn.F_OR_R_R
        || f == insn.F_XOR_I_R || f == insn.F_XOR_R_R
};

// A generated function's shared return sequence, if it has one. Copying
// this at early returns trades code bytes for one fewer taken branch.
def return_tail(body: [long]) -> long {
    let w = insn.IR_W;
    let at = len(body) - 3 * w;
    if (at >= w && body[at] == insn.F_MOV_R_R
        && body[at + 1] == insn.R_RBP && body[at + 2] == 64
        && body[at + 3] == insn.R_RSP && body[at + 4] == 64
        && body[at + w] == insn.F_POP_R
        && body[at + w + 1] == insn.R_RBP && body[at + w + 2] == 64
        && (body[at + 2 * w] == insn.F_RET || body[at + 2 * w] == insn.F_RET_I)) {
        at
    } else { -1 }
};

// Nested expressions can put several end labels at the same return address.
def returns_to(body: [long], tail: long, label: long) -> bool {
    let at = tail - insn.IR_W;
    while (at >= 0 && (body[at] == insn.IR_LABEL || body[at] == insn.IR_LOC)) {
        if (body[at] == insn.IR_LABEL && body[at + 1] == label) { return true; };
        at -= insn.IR_W;
    };
    false
};

// Whether the five-word memory operand at a and the one at b are the same.
def same_mem(body: [long], a: long, b: long) -> bool {
    let i = 0;
    while (i < 5) {
        if (body[a + i] != body[b + i]) { return false; };
        i = i + 1;
    };
    true
};

// Whether the instruction at `at` writes %rax before reading it, so the value
// a removed `mov ..., %rax` produced is dead. A call writes it (its return
// value); a label or anything else is treated as live, which only loses a
// fusion.
def overwrites_rax(body: [long], at: long) -> bool {
    let n = len(body);
    if (at >= n) { return true; };
    let f = body[at];
    if (f == insn.F_CALL_L) { return true; };
    if (f == insn.F_MOV_I_R || f == insn.F_MOV_D_R || f == insn.F_LEA_D_R
        || f == insn.F_LEA_M_R || f == insn.F_LEA_P_R) {
        return body[at + 6] == insn.R_RAX;
    };
    if (f == insn.F_MOV_R_R || f == insn.F_XOR_R_R) { return body[at + 3] == insn.R_RAX; };
    if (f == insn.F_POP_R) { return body[at + 1] == insn.R_RAX; };
    false
};

// The `.loc` items between two code items, moved down to wp (the compaction
// keeps them so a -g build still lines the fused instruction up).
def copy_locs(body: [long], from: long, to: long, wp: long) -> long {
    let w = insn.IR_W;
    let x = from;
    while (x < to) {
        if (body[x] == insn.IR_LOC) {
            for i in 0..w { body[wp + i] = body[x + i]; };
            wp += w;
        };
        x += w;
    };
    wp
};

// Adjacent pairs the emitter cannot see across: a value loaded into a
// register only to be pushed, a constant materialised only to be pushed, a
// binary operation's left operand saved through %rcx, and a store immediately
// reloaded. Each fusion removes one or two instructions from every program
// and from ycc itself, which ycc compiles. `.loc` items do not break a pair.
// Compaction is in place: the output is never longer than the input, and a
// second copy of a whole body would show up in the self-build's peak heap,
// which is already close to its cap.
def fuse(body: [long]) -> [long] {
    let w = insn.IR_W;
    let wp = 0;
    let at = 0;
    let n = len(body);
    while (at < n) {
        let f = body[at];
        let b2 = next_code(body, at + w);
        let b3 = next_code(body, b2 + w);
        let fused = 0;
        if (f == insn.F_MOV_D_R && b2 + w <= n
            && body[at + 7] == 64 && body[at + 6] == insn.R_RAX
            && body[at + 1] != insn.R_RSP && body[at + 2] != insn.R_RSP
            && body[b2] == insn.F_PUSH_R
            && body[b2 + 1] == body[at + 6] && body[b2 + 2] == 64
            && overwrites_rax(body, next_code(body, b2 + w))) {
            // mov slot, %rax; push %rax -> push slot
            let m0 = body[at + 1];
            let m1 = body[at + 2];
            let m2 = body[at + 3];
            let m3 = body[at + 4];
            let m4 = body[at + 5];
            wp = copy_locs(body, at + w, b2, wp);
            body[wp] = insn.F_PUSH_M;
            body[wp + 1] = m0;
            body[wp + 2] = m1;
            body[wp + 3] = m2;
            body[wp + 4] = m3;
            body[wp + 5] = m4;
            for i in 6..w { body[wp + i] = 0; };
            wp += w;
            fused = 2;
        } else if (f == insn.F_MOV_I_R && b2 + w <= n
            && body[at + 2] == insn.R_RAX && body[at + 3] == 64
            && body[b2] == insn.F_PUSH_R && body[b2 + 1] == insn.R_RAX && body[b2 + 2] == 64
            && body[at + 1] >= -2147483648 && body[at + 1] <= 2147483647
            && overwrites_rax(body, next_code(body, b2 + w))) {
            // mov $imm, %rax; push %rax -> push $imm
            let imm = body[at + 1];
            wp = copy_locs(body, at + w, b2, wp);
            body[wp] = insn.F_PUSH_I;
            body[wp + 1] = imm;
            for i in 2..w { body[wp + i] = 0; };
            wp += w;
            fused = 2;
        } else if (f == insn.F_MOV_D_R && b2 + w <= n
            && body[at + 7] == 64 && body[b2] == insn.F_MOV_R_D
            && body[b2 + 1] == body[at + 6] && body[b2 + 2] == 64
            && same_mem(body, at + 1, b2 + 3)) {
            // a load immediately written back to the same slot: the store
            // changes nothing, so it goes and the load (and %rax, which the
            // next instruction may read) stays.
            wp = copy_locs(body, at + w, b2, wp);
            for i in 0..w { body[wp + i] = body[at + i]; };
            wp += w;
            fused = 2;
        } else if (f == insn.F_MOV_R_R && b3 + 4 <= n
            && body[at + 1] == insn.R_RAX && body[at + 2] == 64
            && body[at + 3] == insn.R_RCX && body[at + 4] == 64
            && body[b2] == insn.F_POP_R && body[b2 + 1] == insn.R_RAX && body[b2 + 2] == 64
            && body[b3 + 1] == insn.R_RCX && body[b3 + 2] == 64
            && body[b3 + 3] == insn.R_RAX && body[b3 + 4] == 64
            && (body[b3] == insn.F_ADD_R_R || body[b3] == insn.F_IMUL_R_R
                || body[b3] == insn.F_AND_R_R || body[b3] == insn.F_OR_R_R
                || body[b3] == insn.F_XOR_R_R)) {
            // mov %rax,%rcx; pop %rax; op %rcx,%rax -> pop %rcx; op
            // (commutative only: the operand order swaps, the result does not)
            wp = copy_locs(body, at + w, b2, wp);
            body[wp] = insn.F_POP_R;
            body[wp + 1] = insn.R_RCX;
            body[wp + 2] = 64;
            for i in 3..w { body[wp + i] = 0; };
            wp += w;
            wp = copy_locs(body, b2 + w, b3, wp);
            for i in 0..w { body[wp + i] = body[b3 + i]; };
            wp += w;
            fused = 3;
        };
        if (fused == 0) {
            if (wp != at) { for i in 0..w { body[wp + i] = body[at + i]; }; };
            wp += w;
            at += w;
        } else {
            at = (if (fused == 2) { b2 } else { b3 }) + w;
        };
    };
    while (len(body) > wp) { body.pop(); };
    body
};

def optimize(body: [long], mode: str) -> [long] {
    // One private buffer for both compactions; units keep their original IR.
    let clean = cleanup(cleanup(body[:]));
    clean = fuse(clean);
    let tail = return_tail(clean);
    let out: [long] = [];
    let at = 0;
    while (at < len(clean)) {
        let f = clean[at];
        let p = next_code(clean, at + insn.IR_W);
        if (f == insn.F_MOV_I_R && clean[at + 1] == 0 && clean[at + 3] == 64
            && p < len(clean) && kills_flags(clean[p])) {
            let r = clean[at + 2];
            out = insn.ir_push(out, insn.F_XOR_R_R, r, 32, r, 32, 0, 0, 0);
        } else if (mode == "size" && f == insn.F_MOV_I_R && clean[at + 3] == 64
            && clean[at + 2] != insn.R_RSP && clean[at + 1] >= -128 && clean[at + 1] <= 127) {
            // Three/four bytes instead of five to seven; flags are preserved.
            // Generated Y code has no red zone: all live slots are above rsp.
            out = insn.ir_push(out, insn.F_PUSH_I, clean[at + 1], 0, 0, 0, 0, 0, 0);
            out = insn.ir_push(out, insn.F_POP_R, clean[at + 2], 64, 0, 0, 0, 0, 0);
        } else if (mode == "speed" && tail >= 0 && f == insn.F_JMP_L
            && returns_to(clean, tail, clean[at + 1])) {
            for i in tail..len(clean) { out += clean[i]; };
        } else {
            for i in 0..insn.IR_W { out += clean[at + i]; };
        };
        at += insn.IR_W;
    };
    out
};

export { set_goal, goal, optimize };
