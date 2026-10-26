// obfuscate.y -- opt-in, behaviour-preserving obfuscation of emitted bodies.
//
// The pass runs at final link, after optimize.cleanup has done its work (a
// later cleanup would delete the junk this pass adds) and before the assembler
// sees the items. Everything here is deterministic from one program seed, so
// the same source and seed produce byte-identical output.
//
// The transforms are conservative: a body whose shape is not understood is
// left alone, and the report names what was skipped. Performance and bytes are
// deliberately traded away.

import insn from "./ir.y";
import lbl from "./labels.y";
import wintgt from "./target.y";

type ObfCounts = { bodies: long, frame: long, consts: long, mba: long,
    indirect: long, opaque: long, shuffled: long, vm: long, vm_bc: long,
    junk_bodies: long, junk_bytes: long, patterns: long, skipped: long };

type ObfResult = { ir: [long], txt: [str] };

let obf_mode = "off";
let obf_seed_value = 0;
let obf_seed_set = false;
let obf_run_seed = 0;
let obf_seal_key = 0;
let obf_external_key = 0;
let obf_external_path = "";
let obf_key_fd = -1;
let obf_anti_debug = false;
let obf_no_anti_debug = false;
let obf_suspend_depth = 0;
let obf_body_rng = 0;
let obf_prog_rng = 0;
let obf_label_id = 0;
let obf_counts: ObfCounts = { bodies: 0, frame: 0, consts: 0, mba: 0,
    indirect: 0, opaque: 0, shuffled: 0, vm: 0, vm_bc: 0,
    junk_bodies: 0, junk_bytes: 0, patterns: 0, skipped: 0 };

def mode() -> str { obf_mode };
def seed_value() -> long { obf_seed_value };
def seed_set() -> bool { obf_seed_set };
def seal_key() -> long { obf_seal_key };

def set_mode(m: str) -> void { obf_mode = m; };
def set_seed(v: long) -> void {
    obf_seed_value = v;
    obf_seed_set = true
};

def suspend() -> void { obf_suspend_depth += 1; };
def resume() -> void {
    if (obf_suspend_depth > 0) { obf_suspend_depth -= 1; };
};

def on() -> bool { obf_suspend_depth == 0 && obf_mode != "off" };
def seal_on() -> bool { on() };
def lazy_on() -> bool { on() && !wintgt.target_is_windows() };
def vm_on() -> bool { on() };
// The bytecode interpreter is SysV-flavoured machine code; the PE target uses
// the dispatch-state flatten layer instead.
def flatten_on() -> bool { vm_on() && wintgt.target_is_windows() };
def std_on() -> bool { on() };
def layout_shuffle() -> bool { on() };
def diversity_high() -> bool { on() };

// A seeded permutation of 0..n-1, for the body parts. It consumes the program
// RNG, so the layout is part of the reproducible build.
def shuffle_order(n: long) -> [long] {
    let out: [long] = [];
    for i in 0..n { out += i; };
    if (!on()) { return out; };
    let i = n - 1;
    while (i > 0) {
        let j = 1 + prog_below(i);
        let t = out[i];
        out[i] = out[j];
        out[j] = t;
        i -= 1;
    };
    out
};

// splitmix64's finalizer. One function, one definition of a random bit, in
// this file and in the seam.
def mix64(x: long) -> long {
    let z = x + 0x9E3779B97F4A7C15;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    z ^ (z >>> 31)
};

// A small stable hash of a string (the program's origin, a body's label).
def str_hash(s: str) -> long {
    let h = 0;
    for i in 0..len(s) {
        h = (h * 131 + s[i]) & 0xFFFFFFFFFFFF;
    };
    h
};

def begin(tag: str) -> long {
    if (!on()) {
        obf_seal_key = 0;
        0
    } else {
        obf_run_seed = mix64(obf_seed_value ^ str_hash(tag) ^ 0x6F62F5C1D3E7);
        obf_prog_rng = obf_run_seed;
        obf_label_id = 0;
        obf_suspend_depth = 0;
        obf_counts = { bodies: 0, frame: 0, consts: 0, mba: 0, indirect: 0,
            opaque: 0, shuffled: 0, vm: 0, vm_bc: 0, junk_bodies: 0,
            junk_bytes: 0, patterns: 0, skipped: 0 };
        if (seal_on() && obf_external_key != 0) {
            obf_seal_key = obf_external_key;
        } else if (seal_on()) {
            obf_seal_key = mix64(obf_run_seed ^ 0x5EA15EA15EA1) | 1;
        } else {
            obf_seal_key = 0;
        };
        obf_seal_key
    }
};

// A fresh label name and id. lbl_fresh does not intern (names are expected to
// be unique already), so the counter is what keeps two guards apart.
def obf_fresh(prefix: str) -> long {
    obf_label_id += 1;
    lbl.lbl_fresh(prefix + "_" + tostring(obf_label_id))
};

// ── per-body RNG ────────────────────────────────────────────────────────
def body_rnd() -> long {
    obf_body_rng = mix64(obf_body_rng + 0x9E3779B97F4A7C15);
    obf_body_rng
};

def body_below(n: long) -> long {
    if (n <= 0) { 0 } else { (body_rnd() >>> 1) % n }
};

def prog_rnd() -> long {
    obf_prog_rng = mix64(obf_prog_rng + 0x9E3779B97F4A7C15);
    obf_prog_rng
};

def prog_below(n: long) -> long {
    if (n <= 0) { 0 } else { (prog_rnd() >>> 1) % n }
};

// ── instruction classification ──────────────────────────────────────────

def is_jcc(f: long) -> bool {
    f == insn.F_JE_L || f == insn.F_JNE_L || f == insn.F_JZ_L
        || f == insn.F_JNZ_L || f == insn.F_JS_L || f == insn.F_JGE_L
        || f == insn.F_JLE_L || f == insn.F_JL_L || f == insn.F_JG_L
        || f == insn.F_JB_L || f == insn.F_JNS_L || f == insn.F_JAE_L
        || f == insn.F_JP_L || f == insn.F_JBE_L || f == insn.F_JA_L
        || f == insn.F_JNP_L
};

def is_setcc(f: long) -> bool {
    f == insn.F_SETE_R || f == insn.F_SETNE_R || f == insn.F_SETL_R
        || f == insn.F_SETG_R || f == insn.F_SETGE_R || f == insn.F_SETLE_R
        || f == insn.F_SETA_R || f == insn.F_SETAE_R || f == insn.F_SETNP_R
        || f == insn.F_SETP_R
};

def reads_flags(f: long) -> bool {
    is_jcc(f) || is_setcc(f) || f == insn.F_UCOMISD_R_R
        || f == insn.F_UCOMISD_D_R || f == insn.F_UCOMISD_0_R
};

def writes_flags(f: long) -> bool {
    f == insn.F_ADD_I_R || f == insn.F_ADD_R_R || f == insn.F_ADD_I_D
        || f == insn.F_SUB_I_R || f == insn.F_SUB_R_R || f == insn.F_SUB_I_D
        || f == insn.F_XOR_I_R || f == insn.F_XOR_R_R || f == insn.F_XOR_I_D
        || f == insn.F_AND_I_R || f == insn.F_AND_R_R || f == insn.F_AND_I_D
        || f == insn.F_OR_R_R || f == insn.F_OR_I_R || f == insn.F_OR_I_D
        || f == insn.F_SHL_I_R || f == insn.F_SHL_R_R
        || f == insn.F_SAR_I_R || f == insn.F_SAR_R_R
        || f == insn.F_SHR_I_R || f == insn.F_SHR_R_R
        || f == insn.F_CMP_I_R || f == insn.F_CMP_R_R || f == insn.F_CMP_M_R
        || f == insn.F_CMP_I_D || f == insn.F_TEST_R_R || f == insn.F_TEST_I_R
        || f == insn.F_TEST_R_R_ANY
        || f == insn.F_IMUL_R_R || f == insn.F_IDIV_R || f == insn.F_DIV_R
        || f == insn.F_NEG_R || f == insn.F_NOT_R || f == insn.F_INC_R
        || f == insn.F_INC_D || f == insn.F_DEC_R || f == insn.F_DEC_D
        || f == insn.F_UCOMISD_R_R || f == insn.F_UCOMISD_D_R
        || f == insn.F_UCOMISD_0_R
};

def is_term(f: long) -> bool {
    f == insn.F_JMP_L || f == insn.F_JMP_IND || f == insn.F_RET
        || f == insn.F_RET_I
};

// Are the arithmetic flags dead from `at` on? Conservative: a label, raw
// text, a flag reader or a block transfer ends liveness as "not dead"; a
// flag writer, a call or a return makes them dead.
def flags_dead(ir: [long], at: long) -> bool {
    let p = at + insn.IR_W;
    let dead = false;
    let done = false;
    while (p < len(ir) && !done) {
        let f = ir[p];
        if (f == insn.IR_LOC) {
            p += insn.IR_W;
        } else if (f == insn.IR_LABEL || f == insn.IR_TEXT) {
            done = true;
        } else if (reads_flags(f)) {
            done = true;
        } else if (writes_flags(f)) {
            dead = true;
            done = true;
        } else if (f == insn.F_CALL_L || f == insn.F_CALL_IND
            || f == insn.F_SYSCALL) {
            dead = true;
            done = true;
        } else if (f == insn.F_RET || f == insn.F_RET_I) {
            dead = true;
            done = true;
        } else if (f == insn.F_JMP_L || f == insn.F_JMP_IND) {
            done = true;
        } else {
            p += insn.IR_W;
        };
    };
    dead
};

def is_comment_line(line: str) -> bool {
    let i = 0;
    while (i < len(line) && (line[i] == ' ' || line[i] == '\t')) { i += 1; };
    i >= len(line) || line[i] == '#'
};

def has_raw_text(txt: [str]) -> bool {
    let out = false;
    txt.foreach((e) => {
        if (!is_comment_line(e)) { out = true; };
    });
    out
};

// ── constant and arithmetic encodings ───────────────────────────────────

def imm32(v: long) -> bool { v >= -2147483648 && v <= 2147483647 };

def push_seq(out: [long], f: long, a: long, b: long, c: long, d: long,
        e: long, g: long, h: long) -> [long] {
    insn.ir_push(out, f, a, b, c, d, e, g, h)
};

def const_seq(out: [long], v: long, reg: long) -> [long] {
    let k = body_below(2147483646) - 1073741823;
    let a = v ^ k;
    let shape = body_below(3);
    if (shape == 0) {
        out = push_seq(out, insn.F_MOV_I_R, a, reg, 64, 0, 0, 0, 0);
        out = push_seq(out, insn.F_XOR_I_R, k, reg, 64, 0, 0, 0, 0);
    } else {
        let addv = body_below(1073741822) - 536870911;
        let base = a - addv;
        out = push_seq(out, insn.F_MOV_I_R, base, reg, 64, 0, 0, 0, 0);
        if (shape == 1) {
            out = push_seq(out, insn.F_ADD_I_R, addv, reg, 64, 0, 0, 0, 0);
        } else {
            out = push_seq(out, insn.F_SUB_I_R, 0 - addv, reg, 64, 0, 0, 0, 0);
        };
        out = push_seq(out, insn.F_XOR_I_R, k, reg, 64, 0, 0, 0, 0);
    };
    out
};

def split_const(ir: [long], out: [long], at: long) -> [long] {
    let v = ir[at + 1];
    let reg = ir[at + 2];
    let size = ir[at + 3];
    if (size == 64 && reg != insn.R_RSP && reg != insn.R_RBP
        && flags_dead(ir, at)) {
        obf_counts.consts += 1;
        const_seq(out, v, reg)
    } else {
        let o = out;
        for i in 0..insn.IR_W { o += ir[at + i]; };
        o
    }
};

def split_bitwise(ir: [long], out: [long], at: long) -> [long] {
    let f = ir[at];
    let v = ir[at + 1];
    let reg = ir[at + 2];
    let size = ir[at + 3];
    let can = size == 64 && imm32(v)
        && (f == insn.F_XOR_I_R || f == insn.F_OR_I_R);
    if (!can) {
        let o = out;
        for i in 0..insn.IR_W { o += ir[at + i]; };
        o
    } else {
        let a = 0;
        let b = 0;
        if (f == insn.F_XOR_I_R) {
            a = body_below(2147483646) - 1073741823;
            b = v ^ a;
        } else {
            let mask = body_below(2147483646) - 1073741823;
            a = v & mask;
            b = v ^ a;
        };
        if (!imm32(a) || !imm32(b)) {
            let o = out;
            for i in 0..insn.IR_W { o += ir[at + i]; };
            o
        } else {
            obf_counts.mba += 1;
            let o = push_seq(out, f, a, reg, 64, 0, 0, 0, 0);
            push_seq(o, f, b, reg, 64, 0, 0, 0, 0)
        }
    }
};

// ── frame shift ─────────────────────────────────────────────────────────

def prologue_at(ir: [long]) -> long {
    let at = 0;
    while (at < len(ir) && (ir[at] == insn.IR_LABEL || ir[at] == insn.IR_LOC)) {
        at += insn.IR_W;
    };
    if (at + 2 * insn.IR_W <= len(ir)
        && ir[at] == insn.F_PUSH_R && ir[at + 1] == insn.R_RBP
        && ir[at + 2] == 64
        && ir[at + insn.IR_W] == insn.F_MOV_R_R
        && ir[at + insn.IR_W + 1] == insn.R_RSP
        && ir[at + insn.IR_W + 2] == 64
        && ir[at + insn.IR_W + 3] == insn.R_RBP
        && ir[at + insn.IR_W + 4] == 64) {
        at
    } else {
        -1
    }
};

def shift_mem(ir: [long], delta: long) -> void {
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
                    && ir[w] == insn.R_RBP && ir[w + 4] < 0 && ir[w + 3] < 0) {
                    ir[w + 3] = ir[w + 3] - delta;
                };
                w += insn.ir_kind_words(k);
                ki += 1;
            };
        };
        at += insn.IR_W;
    };
};

def frame_shift(ir: [long], name: str, txt: [str]) -> [long] {
    let p = prologue_at(ir);
    if (p < 0 || name == "_start" || name[:2] == "y_" || has_raw_text(txt)) {
        obf_counts.skipped += 1;
        ir
    } else {
        let delta = 16 + 16 * body_below(4) + (if (diversity_high()) { 32 } else { 0 });
        shift_mem(ir, delta);
        let sub_at = p + 2 * insn.IR_W;
        let has_sub = sub_at < len(ir) && ir[sub_at] == insn.F_SUB_I_R
            && ir[sub_at + 2] == insn.R_RSP && ir[sub_at + 3] == 64;
        if (has_sub) {
            ir[sub_at + 1] = ir[sub_at + 1] + delta;
        } else {
            let out: [long] = [];
            let at = 0;
            while (at < len(ir)) {
                if (at == sub_at) {
                    out = push_seq(out, insn.F_SUB_I_R, delta, insn.R_RSP,
                        64, 0, 0, 0, 0);
                };
                for i in 0..insn.IR_W { out += ir[at + i]; };
                at += insn.IR_W;
            };
            if (sub_at >= len(ir)) {
                out = push_seq(out, insn.F_SUB_I_R, delta, insn.R_RSP, 64,
                    0, 0, 0, 0);
            };
            ir = out;
        };
        // A decoy store or two in the gap the shift opened. The addresses
        // are above the first real slot, so no local can see them.
        let decoys = 1 + body_below(2) + (if (diversity_high()) { 2 } else { 0 });
        let out2: [long] = [];
        let at2 = 0;
        let placed = 0;
        while (at2 < len(ir)) {
            for i in 0..insn.IR_W { out2 += ir[at2 + i]; };
            if (at2 == p + 3 * insn.IR_W && placed < decoys) {
                let d = 0 - 8 - 8 * placed;
                out2 = push_seq(out2, insn.F_MOV_I_D, body_rnd(),
                    insn.R_RBP, -1, 1, d, -1, 0);
                placed += 1;
            };
            at2 += insn.IR_W;
        };
        obf_counts.frame += 1;
        out2
    }
};

// ── opaque guard and junk ───────────────────────────────────────────────

def junk_ops(out: [long], n: long) -> [long] {
    let o = out;
    let i = 0;
    while (i < n) {
        let k = body_below(6);
        if (k == 0) {
            o = push_seq(o, insn.F_MOV_I_R, body_rnd(), insn.R_R11, 64, 0, 0, 0, 0);
        } else if (k == 1) {
            o = push_seq(o, insn.F_ADD_I_R, body_below(1000) - 500,
                insn.R_R11, 64, 0, 0, 0, 0);
        } else if (k == 2) {
            o = push_seq(o, insn.F_XOR_I_R, body_below(1000) - 500,
                insn.R_R11, 64, 0, 0, 0, 0);
        } else if (k == 3) {
            o = push_seq(o, insn.F_SHL_I_R, 1 + body_below(31), insn.R_R11,
                64, 0, 0, 0, 0);
        } else if (k == 4) {
            o = push_seq(o, insn.F_IMUL_R_R, insn.R_R11, 64, insn.R_R11, 64,
                0, 0, 0);
        } else {
            o = push_seq(o, insn.F_NEG_R, insn.R_R11, 64, 0, 0, 0, 0, 0);
        };
        i += 1;
    };
    o
};

// A branch on the incoming scratch value: the two paths are behaviourally
// identical, but the condition is not a constant the way the old even-K
// multiply was. A decompiler must consider both sides; an emulator still
// sees the junk path do nothing observable.
def guard(out: [long]) -> [long] {
    let junk = obf_fresh("yobf_junk");
    let cont = obf_fresh("yobf_cont");
    let mask = 1 + 2 * body_below(8);
    let o = out;
    o = push_seq(o, insn.F_PUSH_R, insn.R_R11, 64, 0, 0, 0, 0, 0);
    o = push_seq(o, insn.F_TEST_I_R, mask, insn.R_R11, 64, 0, 0, 0, 0);
    if (body_below(2) == 0) {
        o = push_seq(o, insn.F_JNZ_L, junk, 0, 0, 0, 0, 0, 0);
    } else {
        o = push_seq(o, insn.F_JZ_L, junk, 0, 0, 0, 0, 0, 0);
    };
    o = push_seq(o, insn.F_JMP_L, cont, 0, 0, 0, 0, 0, 0);
    o = push_seq(o, insn.IR_LABEL, junk, 0, 0, 0, 0, 0, 0);
    o = junk_ops(o, 3 + body_below(7) + (if (diversity_high()) { 4 } else { 0 }));
    o = push_seq(o, insn.IR_LABEL, cont, 0, 0, 0, 0, 0, 0);
    push_seq(o, insn.F_POP_R, insn.R_R11, 64, 0, 0, 0, 0, 0)
};

def opaque(ir: [long], name: str, txt: [str]) -> [long] {
    if (name == "_start" || name[:2] == "y_" || has_raw_text(txt)) {
        ir
    } else {
        let out: [long] = [];
        let at = 0;
        let n = 0;
        while (at < len(ir)) {
            let f = ir[at];
            let guarded = f != insn.IR_LABEL && f != insn.IR_TEXT
                && f != insn.F_RET && f != insn.F_RET_I
                && f != insn.F_JMP_L && f != insn.F_JMP_IND
                && !reads_flags(f)
                && n < (if (diversity_high()) { 10 } else { 6 })
                && body_below(if (diversity_high()) { 2 } else { 3 }) == 0
                && flags_dead(ir, at);
            if (guarded) {
                out = guard(out);
                n += 1;
                obf_counts.opaque += 1;
            };
            for i in 0..insn.IR_W { out += ir[at + i]; };
            at += insn.IR_W;
        };
        out
    }
};

// ── indirect calls ──────────────────────────────────────────────────────

def indirect(ir: [long], name: str) -> [long] {
    if (name == "_start" || name[:2] == "y_") {
        ir
    } else {
        let out: [long] = [];
        let at = 0;
        while (at < len(ir)) {
            if (ir[at] == insn.F_CALL_L && body_below(2) == 0) {
                let target = ir[at + 1];
                out = push_seq(out, insn.F_LEA_P_R, -1, -1, 1, 0, target,
                    insn.R_R11, 64);
                out = push_seq(out, insn.F_CALL_IND, insn.R_R11, 64, 0, 0, 0,
                    0, 0);
                obf_counts.indirect += 1;
            } else {
                for i in 0..insn.IR_W { out += ir[at + i]; };
            };
            at += insn.IR_W;
        };
        out
    }
};

// ── block order ─────────────────────────────────────────────────────────

def block_last_code(ir: [long], lo: long, hi: long) -> long {
    let at = lo;
    let last = -1;
    while (at < hi) {
        let f = ir[at];
        if (f != insn.IR_TEXT && f != insn.IR_LOC) { last = at; };
        at += insn.IR_W;
    };
    last
};

def block_falls(ir: [long], lo: long, hi: long, n: long, i: long) -> long {
    let last = block_last_code(ir, lo, hi);
    if (last < 0) { -1 } else if (is_term(ir[last])) { -1 } else if (i + 1 < n) { i + 1 } else { -1 }
};

def shuffle(ir: [long], name: str, txt: [str]) -> [long] {
    if (name == "_start" || name[:2] == "y_" || has_raw_text(txt)
        || len(ir) < 3 * insn.IR_W || ir[0] != insn.IR_LABEL) {
        ir
    } else {
        let starts: [long] = [];
        let labs: [long] = [];
        let at = 0;
        while (at < len(ir)) {
            if (ir[at] == insn.IR_LABEL) {
                starts += at;
                labs += ir[at + 1];
            };
            at += insn.IR_W;
        };
        let n = len(starts);
        let ok = n >= 3;
        if (ok) {
            let i = 0;
            while (i < n && ok) {
                let hi = len(ir);
                if (i + 1 < n) { hi = starts[i + 1]; };
                if (block_last_code(ir, starts[i], hi) < 0) { ok = false; };
                i += 1;
            };
        };
        if (!ok) {
            ir
        } else {
            let order: [long] = [];
            for i in 0..n { order += i; };
            let i = n - 1;
            while (i > 0) {
                let j = 1 + body_below(i);
                let t = order[i];
                order[i] = order[j];
                order[j] = t;
                i -= 1;
            };
            let out: [long] = [];
            let pos = 0;
            while (pos < n) {
                let b = order[pos];
                let lo = starts[b];
                let hi = len(ir);
                if (b + 1 < n) { hi = starts[b + 1]; };
                for k in lo..hi {
                    out += ir[k];
                };
                let fall = block_falls(ir, lo, hi, n, b);
                if (fall >= 0) {
                    let nextb = -1;
                    if (pos + 1 < n) { nextb = order[pos + 1]; };
                    if (nextb != fall) {
                        let tl = labs[fall];
                        if (tl >= 0) {
                            out = push_seq(out, insn.F_JMP_L, tl, 0, 0, 0, 0, 0, 0);
                        };
                    };
                };
                pos += 1;
            };
            obf_counts.shuffled += 1;
            out
        }
    }
};

// ── the dispatch VM ─────────────────────────────────────────────────────
//
// A selected function keeps its native blocks, but every transfer becomes a
// state assignment and a jump to one dispatcher. The dispatcher is a compare
// chain over random state values, emitted in random order; the blocks are
// emitted in random order too. This is control-flow flattening with a random
// state machine per function -- the "VM" layer of the mode. It needs no ABI
// bridge and preserves every instruction and flag in the blocks.

def block_target(labs: [long], id: long) -> long {
    let out = -1;
    let i = 0;
    while (i < len(labs) && out < 0) {
        if (labs[i] == id) { out = i; };
        i += 1;
    };
    out
};

def vm_eligible(ir: [long], name: str, txt: [str]) -> bool {
    if (name == "_start" || name[:2] == "y_" || has_raw_text(txt)
        || ir[0] != insn.IR_LABEL) {
        false
    } else {
        let starts: [long] = [];
        let at = 0;
        while (at < len(ir)) {
            if (ir[at] == insn.IR_LABEL) { starts += at; };
            at += insn.IR_W;
        };
        let n = len(starts);
        let ok = n >= 3;
        let i = 0;
        while (i < n && ok) {
            let hi = len(ir);
            if (i + 1 < n) { hi = starts[i + 1]; };
            let last = block_last_code(ir, starts[i], hi);
            if (last < 0) { ok = false; };
            if (ok && ir[last] == insn.F_JMP_IND) { ok = false; };
            if (ok && is_term(ir[last]) && ir[last] != insn.F_JMP_L
                && ir[last] != insn.F_RET && ir[last] != insn.F_RET_I) {
                ok = false;
            };
            if (ok && !is_term(ir[last]) && i + 1 >= n) { ok = false; };
            if (ok && is_jcc(ir[last]) && i + 1 >= n) { ok = false; };
            i += 1;
        };
        ok
    }
};

def state_values(n: long) -> [long] {
    let out: [long] = [];
    let i = 0;
    while (i < n) {
        let v = 1 + body_below(1000000000);
        let dup = false;
        out.foreach((e) => {
            if (e == v) { dup = true; };
        });
        if (!dup) {
            out += v;
            i += 1;
        };
    };
    out
};

def flatten(ir: [long], name: str, txt: [str]) -> [long] {
    let eligible = vm_eligible(ir, name, txt);
    if (!eligible) {
        obf_counts.skipped += 1;
        ir
    } else {
        let starts: [long] = [];
        let labs: [long] = [];
        let at = 0;
        while (at < len(ir)) {
            if (ir[at] == insn.IR_LABEL) {
                starts += at;
                labs += ir[at + 1];
            };
            at += insn.IR_W;
        };
        let n = len(starts);
        let states = state_values(n);
        let setters: [long] = [];
        for i in 0..n { setters += obf_fresh("yvm_set"); };
        let disp_a = obf_fresh("yvm_disp_a");
        let disp_b = obf_fresh("yvm_disp_b");
        let bogus_label = obf_fresh("yvm_bogus");
        // A state that no setter uses: a guessed/patch state lands in a
        // realistic-looking dead block instead of the dispatcher default.
        let bogus_state = 1 + body_below(1000000000);
        let bdup = true;
        while (bdup) {
            bdup = false;
            for i in 0..n { if (states[i] == bogus_state) { bdup = true; }; };
            if (bdup) { bogus_state = 1 + body_below(1000000000); };
        };
        let order: [long] = [];
        order += 0;
        for i in 1..n { order += i; };
        let i = n - 1;
        while (i > 0) {
            let j = 1 + body_below(i);
            let t = order[i];
            order[i] = order[j];
            order[j] = t;
            i -= 1;
        };
        let out: [long] = [];
        let pos = 0;
        while (pos < n) {
            let b = order[pos];
            let lo = starts[b];
            let hi = len(ir);
            if (b + 1 < n) { hi = starts[b + 1]; };
            let last = block_last_code(ir, lo, hi);
            let f = ir[last];
            let k = lo;
            while (k < hi) {
                if (k == last && (f == insn.F_JMP_L || is_jcc(f))) {
                    // replaced below
                    k = hi;
                } else {
                    if (k == last && (f == insn.F_RET || f == insn.F_RET_I)) {
                        for q in 0..insn.IR_W { out += ir[k + q]; };
                    } else if (k == last) {
                        // normal fallthrough: emit the item, then the setter
                        for q in 0..insn.IR_W { out += ir[k + q]; };
                        let fall = b + 1;
                        if (fall < n) {
                            out = push_seq(out, insn.F_JMP_L, setters[fall], 0, 0, 0, 0, 0, 0);
                        };
                    } else {
                        for q in 0..insn.IR_W { out += ir[k + q]; };
                    };
                    k += insn.IR_W;
                };
            };
            if (f == insn.F_JMP_L) {
                let tb = block_target(labs, ir[last + 1]);
                if (tb >= 0) {
                    out = push_seq(out, insn.F_JMP_L, setters[tb], 0, 0, 0, 0, 0, 0);
                } else {
                    // a jump out of the function (a trap or a runtime label):
                    // it is not a block, so leave it a direct jump.
                    for q in 0..insn.IR_W { out += ir[last + q]; };
                };
            } else if (is_jcc(f)) {
                let tb = block_target(labs, ir[last + 1]);
                if (tb >= 0) {
                    let item: [long] = [];
                    for q in 0..insn.IR_W { item += ir[last + q]; };
                    item[1] = setters[tb];
                    for q in 0..insn.IR_W { out += item[q]; };
                } else {
                    for q in 0..insn.IR_W { out += ir[last + q]; };
                };
                if (b + 1 < n) {
                    out = push_seq(out, insn.F_JMP_L, setters[b + 1], 0, 0, 0, 0, 0, 0);
                };
            };
            pos += 1;
        };
        for i in 0..n {
            let hub = disp_b;
            if ((states[i] & 1) == 0) { hub = disp_a; };
            out = push_seq(out, insn.IR_LABEL, setters[i], 0, 0, 0, 0, 0, 0);
            out = push_seq(out, insn.F_MOV_I_R, states[i], insn.R_R11, 64, 0, 0, 0, 0);
            out = push_seq(out, insn.F_JMP_L, hub, 0, 0, 0, 0, 0, 0);
        };
        // Two shuffled compare chains, each holding half the states. A
        // decompiler still sees a switch, but not one hot block for the whole
        // function; the setter chooses the hub from the state itself.
        let h = 0;
        while (h < 2) {
            out = push_seq(out, insn.IR_LABEL, if (h == 0) { disp_a } else { disp_b },
                0, 0, 0, 0, 0, 0);
            let d = 0;
            while (d < n) {
                let b = order[d];
                if ((states[b] & 1) == h) {
                    out = push_seq(out, insn.F_CMP_I_R, states[b], insn.R_R11,
                        64, 0, 0, 0, 0);
                    out = push_seq(out, insn.F_JE_L, labs[b], 0, 0, 0, 0, 0, 0);
                };
                d += 1;
            };
            if (h == 1 || diversity_high()) {
                out = push_seq(out, insn.F_CMP_I_R, bogus_state, insn.R_R11,
                    64, 0, 0, 0, 0);
                out = push_seq(out, insn.F_JE_L, bogus_label, 0, 0, 0, 0, 0, 0);
            };
            out = push_seq(out, insn.F_MOV_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
            out = push_seq(out, insn.F_RET, 0, 0, 0, 0, 0, 0, 0);
            h += 1;
        };
        out = push_seq(out, insn.IR_LABEL, bogus_label, 0, 0, 0, 0, 0, 0);
        out = junk_ops(out, 2 + body_below(5) + (if (diversity_high()) { 4 } else { 0 }));
        out = push_seq(out, insn.F_MOV_I_R, 0, insn.R_RAX, 64, 0, 0, 0, 0);
        out = push_seq(out, insn.F_RET, 0, 0, 0, 0, 0, 0, 0);
        obf_counts.vm += 1;
        out
    }
};

// ── instruction substitution ────────────────────────────────────────────

type SubRes = { hit: bool, out: [long] };

// Rewrites that keep the value and only need the flags to be dead afterwards.
// They are not a security boundary either: they break the compiler's own
// pattern, not a determined decompiler.
def substitute(ir: [long], out: [long], at: long) -> SubRes {
    let f = ir[at];
    let reg = ir[at + 2];
    let size = ir[at + 3];
    let can = size == 64 && reg != insn.R_RSP && reg != insn.R_RBP
        && (diversity_high() || body_below(2) == 0) && flags_dead(ir, at);
    if (!can) {
        { hit: false, out: out }
    } else if (f == insn.F_ADD_I_R && imm32(0 - ir[at + 1])) {
        obf_counts.patterns += 1;
        { hit: true, out: push_seq(out, insn.F_SUB_I_R, 0 - ir[at + 1],
            reg, 64, 0, 0, 0, 0) }
    } else if (f == insn.F_XOR_I_R && ir[at + 1] == -1) {
        obf_counts.patterns += 1;
        { hit: true, out: push_seq(out, insn.F_NOT_R, reg, 64, 0, 0, 0, 0, 0) }
    } else if (f == insn.F_MOV_I_R && ir[at + 1] == 0) {
        obf_counts.patterns += 1;
        { hit: true, out: push_seq(out, insn.F_XOR_R_R, reg, 64, reg, 64,
            0, 0, 0) }
    } else {
        { hit: false, out: out }
    }
};

// ── the body pass ───────────────────────────────────────────────────────

def transform(ir: [long], txt: [str], name: str) -> ObfResult {
    obf_body_rng = mix64(obf_run_seed ^ str_hash(name) ^ 0xB0D1E5);
    obf_counts.bodies += 1;
    let body = frame_shift(ir, name, txt);
    let out: [long] = [];
    let at = 0;
    while (at < len(body)) {
        let f = body[at];
        if (f == insn.F_MOV_I_R) {
            let sub = substitute(body, out, at);
            if (sub.hit) { out = sub.out; } else { out = split_const(body, out, at); };
        } else if (f == insn.F_XOR_I_R || f == insn.F_OR_I_R) {
            let sub = substitute(body, out, at);
            if (sub.hit) { out = sub.out; } else { out = split_bitwise(body, out, at); };
        } else if (f == insn.F_ADD_I_R) {
            let sub = substitute(body, out, at);
            if (sub.hit) { out = sub.out; } else {
                for i in 0..insn.IR_W { out += body[at + i]; };
            };
        } else {
            for i in 0..insn.IR_W { out += body[at + i]; };
        };
        at += insn.IR_W;
    };
    out = indirect(out, name);
    if (flatten_on()) {
        out = flatten(out, name, txt);
    } else {
        out = shuffle(out, name, txt);
    };
    out = opaque(out, name, txt);
    junk_jumps(out, txt, name)
};

// A jump over random bytes inside a body. A linear-sweep disassembler
// decodes the bytes; the CPU and a recursive disassembler follow the jump.
// The bytes are never executed, so their content only has to look plausible.
def junk_jumps(ir: [long], txt: [str], name: str) -> ObfResult {
    if (name == "_start" || name[:2] == "y_" || has_raw_text(txt)) {
        { ir: ir, txt: txt }
    } else {
        let out: [long] = [];
        let at = 0;
        let added = 0;
        while (at < len(ir)) {
            let f = ir[at];
            for i in 0..insn.IR_W { out += ir[at + i]; };
            let ok = f != insn.IR_LABEL && f != insn.IR_TEXT
                && f != insn.F_JMP_L && f != insn.F_JMP_IND
                && f != insn.F_RET && f != insn.F_RET_I
                && added < (if (diversity_high()) { 5 } else { 3 })
                && body_below(if (diversity_high()) { 2 } else { 3 }) == 0
                && flags_dead(ir, at);
            if (ok) {
                let cont = obf_fresh("yobf_jcont");
                let n = 4 + body_below(13);
                let parts: [str] = [];
                let i = 0;
                while (i < n) {
                    parts += tostring(body_below(256));
                    i += 1;
                };
                txt += ".byte " + join(parts, ",");
                out = push_seq(out, insn.F_JMP_L, cont, 0, 0, 0, 0, 0, 0);
                out = push_seq(out, insn.IR_TEXT, len(txt) - 1, 0, 0, 0, 0, 0, 0);
                out = push_seq(out, insn.IR_LABEL, cont, 0, 0, 0, 0, 0, 0);
                obf_counts.junk_bytes += n;
                added += 1;
            };
            at += insn.IR_W;
        };
        { ir: out, txt: txt }
    }
};

// ── program-level junk ──────────────────────────────────────────────────

def junk_body(n: long) -> ObfResult {
    let label = obf_fresh("yobf_dead");
    let ir: [long] = [];
    ir = push_seq(ir, insn.IR_LABEL, label, 0, 0, 0, 0, 0, 0);
    let count = 4 + prog_below(9);
    let i = 0;
    while (i < count) {
        let k = prog_below(8);
        if (k == 0) {
            ir = push_seq(ir, insn.F_MOV_I_R, prog_rnd(), insn.R_R10, 64, 0, 0, 0, 0);
        } else if (k == 1) {
            ir = push_seq(ir, insn.F_ADD_I_R, prog_below(1000) - 500,
                insn.R_R10, 64, 0, 0, 0, 0);
        } else if (k == 2) {
            ir = push_seq(ir, insn.F_XOR_I_R, prog_below(1000) - 500,
                insn.R_R10, 64, 0, 0, 0, 0);
        } else if (k == 3) {
            ir = push_seq(ir, insn.F_OR_I_R, prog_below(1000) - 500,
                insn.R_R10, 64, 0, 0, 0, 0);
        } else if (k == 4) {
            ir = push_seq(ir, insn.F_AND_I_R, prog_below(1000) - 500,
                insn.R_R10, 64, 0, 0, 0, 0);
        } else if (k == 5) {
            ir = push_seq(ir, insn.F_SHL_I_R, 1 + prog_below(31), insn.R_R10,
                64, 0, 0, 0, 0);
        } else if (k == 6) {
            ir = push_seq(ir, insn.F_IMUL_R_R, insn.R_R10, 64, insn.R_R10, 64,
                0, 0, 0);
        } else {
            ir = push_seq(ir, insn.F_NEG_R, insn.R_R10, 64, 0, 0, 0, 0, 0);
        };
        i += 1;
    };
    ir = push_seq(ir, insn.F_RET, 0, 0, 0, 0, 0, 0, 0);
    let none: [str] = [];
    { ir: ir, txt: none }
};

def junk_bodies() -> [ObfResult] {
    let out: [ObfResult] = [];
    if (!on()) { return out; };
    let n = 1 + prog_below(3);
    for i in 0..n {
        out += [junk_body(i)];
        obf_counts.junk_bodies += 1;
    };
    out
};

def junk_bytes() -> str {
    if (!on()) { return ""; };
    let n = 8 + prog_below(48);
    let parts: [str] = [];
    let i = 0;
    while (i < n) {
        parts += tostring(prog_below(256));
        i += 1;
    };
    obf_counts.junk_bytes += n;
    ".byte " + join(parts, ",") + "\n"
};

def note_vm_bc() -> void { obf_counts.vm_bc += 1; };
def program_seed() -> long { obf_run_seed };
def path_key() -> long { mix64(obf_run_seed ^ 0x504154484B4559) | 1 };
def build_id() -> long {
    mix64(obf_seed_value ^ str_hash(obf_mode) ^ 0x4255494C44)
};

def set_external_key(key: long, path: str) -> void {
    obf_external_key = key;
    obf_external_path = path;
};
def key_file() -> str { obf_external_path };
def set_key_fd(fd: long) -> void { obf_key_fd = fd; };
def key_fd() -> long { obf_key_fd };
def set_anti_debug(onoff: bool) -> void { obf_anti_debug = onoff; };
def anti_debug() -> bool { obf_anti_debug };
def set_no_anti_debug(onoff: bool) -> void { obf_no_anti_debug = onoff; };
def no_anti_debug() -> bool { obf_no_anti_debug };

def report() -> [str] {
    let out: [str] = [];
    if (!on()) { return out; };
    let seed = obf_seed_value;
    out += "obfuscate: mode=" + obf_mode + " seed=" + tostring(seed)
        + " build=" + tostring(build_id()) + " layout=shuffle"
        + " std=all diversity=high";
    if (obf_mode == "full") { out += " vm=bytecode"; };
    out += "obfuscate: bodies=" + tostring(obf_counts.bodies)
        + " frame=" + tostring(obf_counts.frame)
        + " consts=" + tostring(obf_counts.consts)
        + " mba=" + tostring(obf_counts.mba)
        + " indirect=" + tostring(obf_counts.indirect)
        + " opaque=" + tostring(obf_counts.opaque)
        + " shuffled=" + tostring(obf_counts.shuffled)
        + " vm=" + tostring(obf_counts.vm)
        + " bytecode=" + tostring(obf_counts.vm_bc)
        + " patterns=" + tostring(obf_counts.patterns)
        + " dead=" + tostring(obf_counts.junk_bodies)
        + " bytes=" + tostring(obf_counts.junk_bytes)
        + " skipped=" + tostring(obf_counts.skipped);
    out
};

export { ObfCounts, ObfResult, set_mode, mode, set_seed, seed_value,
    seed_set, seal_key, suspend, resume, on, seal_on, lazy_on,
    vm_on, flatten_on, std_on, layout_shuffle, diversity_high, shuffle_order, begin, transform, junk_bodies, junk_bytes, report, mix64,
    program_seed, path_key, build_id, note_vm_bc, set_external_key, key_file, set_key_fd, key_fd,
    set_anti_debug, anti_debug, set_no_anti_debug, no_anti_debug };
