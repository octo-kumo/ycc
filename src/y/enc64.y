// enc64.y — x86-64 instruction encoding for the native backend's subset.
// Operands use the assembler's parsed forms (asm.y parse_operand):
//   {k:K.reg, n, size}      n = 0-15, size = 64/32/8 (128 = an xmm)
//   {k:K.imm, v}            signed long
//   {k:K.mem, base, idx, scale, disp, rip, lbl}  rip: bool (lbl valid),
//     base/idx: reg numbers (-1 = none), scale 1/2/4/8, disp long
//   {k:K.lbl, name}         code label (jumps/calls)
//   {k:K.ind, n, size}      call *%reg — an indirect target (closure code)
//   {k:K.diff, a, b}        a-b as imm32 (rodata lengths)
// Every enc_* returns {bytes: [byte] (values 0-255), fix: [...], err: str};
// le16/le32/le64/byte_of return the [byte] buffer itself.
// Only the forms our backend emits exist here — anything else is a loud
// error from the assembler, never a silent miscompile.
//
// The C copy in src/c compiles this file, so every construct used here
// needs a twin there (PORTING.md).

// An operand, any of the forms above: every one carries every field (the
// ones its form does not use are 0 / "" / false), so a read is a load.
import tags from "./tags.y";
type Operand = { k: long, n: long, size: long, v: long, a: str, b: str, name: str, base: long, idx: long, scale: long, disp: long, rip: bool, lbl: str };

// A register operand (see above).
type Reg = { k: long, n: long, size: long };

def r64(n: long) -> Reg { { k: K.reg, n: n, size: 64 } };
def r32(n: long) -> Reg { { k: K.reg, n: n, size: 32 } };
def r8(n: long) -> Reg { { k: K.reg, n: n, size: 8 } };

// Register number by AT&T name. Supports the registers our backend uses.
def reg_num(name: str) -> long {
    if (name == "%rax" || name == "%eax" || name == "%al") { 0 }
    else if (name == "%rcx" || name == "%ecx" || name == "%cl") { 1 }
    else if (name == "%rdx" || name == "%edx" || name == "%dl") { 2 }
    else if (name == "%rbx" || name == "%ebx" || name == "%bl") { 3 }
    else if (name == "%rsp" || name == "%esp") { 4 }
    else if (name == "%rbp" || name == "%ebp") { 5 }
    else if (name == "%rsi" || name == "%esi" || name == "%sil") { 6 }
    else if (name == "%rdi" || name == "%edi" || name == "%dil") { 7 }
    else if (name == "%r8" || name == "%r8d" || name == "%r8b") { 8 }
    else if (name == "%r9" || name == "%r9d" || name == "%r9b") { 9 }
    else if (name == "%r10" || name == "%r10d" || name == "%r10b") { 10 }
    else if (name == "%r11" || name == "%r11d" || name == "%r11b") { 11 }
    else if (name == "%r12" || name == "%r12d") { 12 }
    else if (name == "%r13" || name == "%r13d") { 13 }
    else if (name == "%r14" || name == "%r14d") { 14 }
    else if (name == "%r15" || name == "%r15d") { 15 }
    else if (name == "%xmm0") { 0 }
    else if (name == "%xmm1") { 1 }
    else if (name == "%xmm2") { 2 }
    else if (name == "%xmm3") { 3 }
    else if (name == "%xmm4") { 4 }
    else if (name == "%xmm5") { 5 }
    else { -1 }
};

def reg_size(name: str) -> long {
    let c = name[1];
    if (c == c'x') {
        // %xmmN: SSE register (size 128 marks the class apart from GPRs)
        128
    } else if (c == c'r') {
        // %r..: 64-bit, unless ends in d/b
        let last = name[len(name) - 1];
        if (last == c'd') { 32 } else if (last == c'b') { 8 } else { 64 }
    } else {
        // %e..: 32-bit; %..l / %..h legacy: 8-bit; %r.. handled above
        if (c == c'e') { 32 } else { 8 }
    }
};

// Safe size read: a non-register yields 0, whatever its `.size` holds.
def op_size(o: Operand) -> long {
    if (o.k == K.reg) { o.size } else { 0 }
};
def rex(w: bool, r: long, x: long, b: long) -> long {
    let v = 64;
    if (w) { v = v + 8; };
    if (r >= 8) { v = v + 4; };
    if (x >= 8) { v = v + 2; };
    if (b >= 8) { v = v + 1; };
    if (v == 64) { -1 } else { v }
};

def modrm(mod: long, reg: long, rm: long) -> long {
    mod * 64 + (reg % 8) * 8 + rm % 8
};

def sib(scale: long, index: long, base: long) -> long {
    let s = 0;
    if (scale == 2) { s = 1; } 
    else if (scale == 4) { s = 2; } 
    else if (scale == 8) { s = 3; };
    s * 64 + (index % 8) * 8 + base % 8
};

def le16(v: long) -> [byte] {
    let out: [byte] = [byte_of(v, 0), byte_of(v, 1)];
    out
};

def le32(v: long) -> [byte] {
    let out: [byte] = [byte_of(v, 0), byte_of(v, 1), byte_of(v, 2), byte_of(v, 3)];
    out
};

def le64(v: long) -> [byte] {
    let out: [byte] = [byte_of(v, 0), byte_of(v, 1), byte_of(v, 2), byte_of(v, 3),
                       byte_of(v, 4), byte_of(v, 5), byte_of(v, 6), byte_of(v, 7)];
    out
};

// 256^i (the weight of byte i).
def pow256(i: long) -> long {
    let r = 1;
    let j = 0;
    while (j < i) {
        r = r * 256;
        j = j + 1;
    };
    r
};

def div_floor(v: long, d: long) -> long {
    // NOTE: Y division truncates toward zero (C semantics — native.y emits
    // `cqo; idiv` for `/`), so floor needs a correction when the remainder
    // is nonzero and the signs differ. Both engines truncate the same way,
    // so one correction serves them both.
    let q = v / d;
    let r = v - q * d;
    if (r != 0) {
        if (v < 0) {
            if (d > 0) { q = q - 1; };
        } else if (d < 0) { q = q - 1; };
    };
    q
};

// Exact byte i (0 = least significant) of a signed long. Y division
// truncates, so floor it manually — correct for negatives (unlike %).
def byte_of(v: long, i: long) -> long {
    let q = div_floor(v, pow256(i));
    q - div_floor(q, 256) * 256
};

def u8(v: long) -> long {
    byte_of(v, 0)
};

// fits in a signed 8-bit immediate?
def fits8(v: long) -> bool {
    v >= -128 && v <= 127
};

// Encode a memory operand tail (ModRM + optional SIB + displacement).
// Returns {modrm, extra: [byte], rip_lbl/"", disp32: bool} — the caller
// supplies the reg field and any label fixup.
type MemTail = { modrm: long, extra: [byte], rip_lbl: str, disp32: bool };
def mem_tail(m: Operand, reg: long) -> MemTail {
    if (m.rip) {
        { modrm: modrm(0, reg, 5), extra: [], rip_lbl: m.lbl, disp32: true }
    } else if (m.idx < 0) {
        // no index: [base+disp]. Low 101 (rbp/r13) needs at least disp8
        // (mod=00 would mean disp32-only); low 100 (rsp/r12) needs a SIB
        // byte whose base field is 100 — which is rsp, or r12 once REX.B
        // widens it (rex_rm sets that from m.base).
        if (m.base % 8 == 5) {
            if (fits8(m.disp)) {
                let extra: [byte] = [u8(m.disp)];
                { modrm: modrm(1, reg, 5), extra: extra, rip_lbl: "", disp32: false }
            } else {
                { modrm: modrm(2, reg, 5), extra: le32(m.disp), rip_lbl: "", disp32: false }
            }
        } else if (m.base % 8 == 4) {
            // rsp/r12 as base: SIB byte required (index=none, base=rsp).
            // sib(1, 4, 4) = scale 00, index 100 (none), base 100 (rsp).
            let s = sib(1, 4, 4);
            if (m.disp == 0) {
                let extra: [byte] = [s];
                { modrm: modrm(0, reg, 4), extra: extra, rip_lbl: "", disp32: false }
            } else if (fits8(m.disp)) {
                let extra: [byte] = [s, u8(m.disp)];
                { modrm: modrm(1, reg, 4), extra: extra, rip_lbl: "", disp32: false }
            } else {
                let prefix: [byte] = [s];
                { modrm: modrm(2, reg, 4), extra: concat(prefix, le32(m.disp)), rip_lbl: "", disp32: false }
            }
        } else if (m.disp == 0) {
            { modrm: modrm(0, reg, m.base), extra: [], rip_lbl: "", disp32: false }
        } else if (fits8(m.disp)) {
            let extra: [byte] = [u8(m.disp)];
            { modrm: modrm(1, reg, m.base), extra: extra, rip_lbl: "", disp32: false }
        } else {
            { modrm: modrm(2, reg, m.base), extra: le32(m.disp), rip_lbl: "", disp32: false }
        }
    } else {
        // SIB: [base + idx*scale + disp]. Low 101 needs explicit disp.
        let s = sib(m.scale, m.idx, m.base);
        if (m.base % 8 == 5) {
            if (fits8(m.disp)) {
                let extra: [byte] = [s, u8(m.disp)];
                { modrm: modrm(1, reg, 4), extra: extra, rip_lbl: "", disp32: false }
            } else {
                let prefix: [byte] = [s];
                { modrm: modrm(2, reg, 4), extra: concat(prefix, le32(m.disp)), rip_lbl: "", disp32: false }
            }
        } else if (m.disp == 0) {
            let extra: [byte] = [s];
            { modrm: modrm(0, reg, 4), extra: extra, rip_lbl: "", disp32: false }
        } else if (fits8(m.disp)) {
            let extra: [byte] = [s, u8(m.disp)];
            { modrm: modrm(1, reg, 4), extra: extra, rip_lbl: "", disp32: false }
        } else {
            let prefix: [byte] = [s];
            { modrm: modrm(2, reg, 4), extra: concat(prefix, le32(m.disp)), rip_lbl: "", disp32: false }
        }
    }
};

// REX for r/m operands: W + extensions from reg field and mem SIB/base.
def rex_rm(w: bool, reg: long, m: Operand) -> long {
    if (m.rip) {
        rex(w, reg, -1, -1)
    } else if (m.idx < 0) {
        rex(w, reg, -1, m.base)
    } else {
        rex(w, reg, m.idx, m.base)
    }
};

def concat(a: [byte], b: [byte]) -> [byte] {
    let out: [byte] = [];
    let i = 0;
    while (i < len(a)) {
        out += a[i];
        i = i + 1;
    };
    let j = 0;
    while (j < len(b)) {
        out += b[j];
        j = j + 1;
    };
    out
};

// Fixup record for label-relative fields, resolved in pass 2:
// {off, kind, lbl, lbl2} (off relative to instruction start).
// kind: "rel32" (call/jmp/jcc), "rip32", "imm32diff".
type Fixup = { off: long, kind: str, lbl: str, lbl2: str };
def fixup(at: long, kind: str, lbl: str, lbl2: str) -> Fixup {
    { off: at, kind: kind, lbl: lbl, lbl2: lbl2 }
};

// ── instruction encoders ───────────────────────────────────────────────
// Each returns {bytes, fix: [{off, kind, lbl, lbl2}], err} with off relative
// to the instruction start. Only forms our backend emits exist.
type Encoded = { bytes: [byte], fix: [Fixup], err: str };

def with_rex(r: long, bytes: [byte]) -> [byte] {
    if (r < 0) {
        bytes
    } else {
        let prefix: [byte] = [r];
        concat(prefix, bytes)
    }
};

def enc_push(o: Operand) -> Encoded {
    if (o.k != K.reg) {
        { bytes: [], fix: [], err: "push needs r64" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "push needs r64" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b: [byte] = [80 + (o.n % 8)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_pop(o: Operand) -> Encoded {
    if (o.k != K.reg) {
        { bytes: [], fix: [], err: "pop needs r64" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "pop needs r64" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b: [byte] = [88 + (o.n % 8)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_mov(dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && src.k == K.reg) {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            let r = rex(true, src.n, -1, dst.n);
            let b: [byte] = [137, modrm(3, src.n, dst.n)];
            { bytes: with_rex(r, b), fix: [], err: "" }
        } else {
            { bytes: [], fix: [], err: "mov reg,reg size mix" }
        }
    } else if (dst.k == K.reg && src.k == K.imm) {
        if (op_size(dst) == 64) {
            if (src.v >= -2147483648 && src.v <= 2147483647) {
                let r = rex(true, -1, -1, dst.n);
                let prefix: [byte] = [199, modrm(3, 0, dst.n)];
                let b = concat(prefix, le32(src.v));
                { bytes: with_rex(r, b), fix: [], err: "" }
            } else {
                let r = rex(true, -1, -1, dst.n);
                let prefix: [byte] = [184 + (dst.n % 8)];
                let b = concat(prefix, le64(src.v));
                { bytes: with_rex(r, b), fix: [], err: "" }
            }
        } else if (op_size(dst) == 32) {
            let r = rex(false, -1, -1, dst.n);
            let prefix: [byte] = [199, modrm(3, 0, dst.n)];
            let b = concat(prefix, le32(src.v));
            { bytes: with_rex(r, b), fix: [], err: "" }
        } else {
            { bytes: [], fix: [], err: "mov imm size" }
        }
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.diff) {
        let r = rex(true, -1, -1, dst.n);
        let prefix: [byte] = [199, modrm(3, 0, dst.n)];
        let zeros: [byte] = [0, 0, 0, 0];
        let b = concat(prefix, zeros);
        let off = 3;
        if (r < 0) { off = 2; 0; };
        { bytes: with_rex(r, b), fix: [fixup(off, "imm32diff", src.a, src.b)], err: "" }
    } else if (dst.k == K.reg && src.k == K.fs && op_size(dst) == 64) {
        // mov %fs:disp32, r64: the fs prefix, REX.W, 8B, a SIB with no
        // base and no index (an absolute disp32)
        let b: [byte] = [100, rex(true, dst.n, -1, -1), 139, modrm(0, dst.n, 4), 37];
        { bytes: concat(b, le32(src.disp)), fix: [], err: "" }
    } else if (dst.k == K.reg && src.k == K.mem) {
        if (op_size(dst) == 64) {
            let t = mem_tail(src, dst.n);
            let r = rex_rm(true, dst.n, src);
            let prefix: [byte] = [139, t.modrm];
            let b = concat(prefix, t.extra);
            enc_mem_result(r, b, t)
        } else {
            { bytes: [], fix: [], err: "mov r,mem size" }
        }
    } else if (dst.k == K.mem && src.k == K.imm) {
        // mov $imm32, mem (length/cap stores)
        let t = mem_tail(dst, 0);
        let r = rex_rm(true, 0, dst);
        let prefix: [byte] = [199, t.modrm];
        let b = concat(concat(prefix, t.extra), le32(src.v));
        enc_mem_result(r, b, t)
    } else if (dst.k == K.mem && src.k == K.reg) {
        if (op_size(src) == 64) {
            let t = mem_tail(dst, src.n);
            let r = rex_rm(true, src.n, dst);
            let prefix: [byte] = [137, t.modrm];
            let b = concat(prefix, t.extra);
            enc_mem_result(r, b, t)
        } else if (op_size(src) == 8) {
            let t = mem_tail(dst, src.n);
            let r = rex_rm(false, src.n, dst);
            let prefix: [byte] = [136, t.modrm];
            let b = concat(prefix, t.extra);
            enc_mem_result(r, b, t)
        } else {
            { bytes: [], fix: [], err: "mov mem,reg size" }
        }
    } else {
        { bytes: [], fix: [], err: "mov form" }
    }
};
// xchg r64, mem (either order): REX.W 87 /r, locked by the processor
// (the threads' mutexes).
def enc_xchg(a: Operand, b: Operand) -> Encoded {
    let reg = a;
    let mem = b;
    if (a.k == K.mem) {
        reg = b;
        mem = a;
    };
    if (reg.k != K.reg || mem.k != K.mem || op_size(reg) != 64) {
        { bytes: [], fix: [], err: "xchg form" }
    } else {
        let t = mem_tail(mem, reg.n);
        let r = rex_rm(true, reg.n, mem);
        let prefix: [byte] = [135, t.modrm];
        enc_mem_result(r, concat(prefix, t.extra), t)
    }
};

def enc_mem_result(r: long, b: [byte], t: MemTail) -> Encoded {
    if (t.modrm < 0) {
        { bytes: [], fix: [], err: "bad memory form" }
    } else {
        let fx: [Fixup] = [];
        let bb = b;
        if (t.disp32) {
            if (t.rip_lbl != "") {
            // fixup offset counts the REX prefix with_rex is about to add;
            // the disp32 placeholder bytes must exist for the patch to land.
                let off = len(b);
                if (r >= 0) { off = off + 1; 0; };
                fx += fixup(off, "rip32", t.rip_lbl, "");
                let zeros: [byte] = [0, 0, 0, 0];
                bb = concat(b, zeros);
            };
        };
        { bytes: with_rex(r, bb), fix: fx, err: "" }
    }
};

def enc_movb(dst: Operand, src: Operand) -> Encoded {
    // movb $imm8, mem
    if (dst.k != K.mem) {
        { bytes: [], fix: [], err: "movb form" }
    } else if (src.k != K.imm) {
        { bytes: [], fix: [], err: "movb form" }
    } else {
        enc_movb_imm(dst, src)
    }
};

def enc_movb_imm(dst: Operand, src: Operand) -> Encoded {
    // (split: shape gate above narrows; this body sees mem/imm only.)
    if (src.v < -128) {
        { bytes: [], fix: [], err: "movb imm range" }
    } else if (src.v > 127) {
        { bytes: [], fix: [], err: "movb imm range" }
    } else {
        let t = mem_tail(dst, 0);
        let r = rex_rm(false, 0, dst);
        let prefix: [byte] = [198, t.modrm];
        let imm: [byte] = [u8(src.v)];
        let b = concat(concat(prefix, t.extra), imm);
        enc_mem_result(r, b, t)
    }
};

def enc_movzbq(dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 8) {
        let r = rex(true, dst.n, -1, src.n);
        let b: [byte] = [15, 182, modrm(3, dst.n, src.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        // movzbq mem8 -> r64 (single-byte loads for string data)
        let t = mem_tail(src, dst.n);
        let r = rex_rm(true, dst.n, src);
        let prefix: [byte] = [15, 182, t.modrm];
        let b = concat(prefix, t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "movzbq form" }
    }
};

def enc_lea(dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        let r = rex_rm(true, dst.n, src);
        let prefix: [byte] = [141, t.modrm];
        let b = concat(prefix, t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "lea form" }
    }
};

def enc_arith(op: str, dst: Operand, src: Operand) -> Encoded {
    // op: add/sub/xor/and/or/cmp/test; r64,r64 only here
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        let base = 1;
        if (op == "sub") { base = 41; }
        else if (op == "xor") { base = 49; }
        else if (op == "and") { base = 33; }
        else if (op == "or") { base = 9; }
        else if (op == "cmp") { base = 57; }
        else if (op == "test") { base = 133; }
        let r = rex(true, src.n, -1, dst.n);
        let b: [byte] = [base, modrm(3, src.n, dst.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "arith reg form" }
    }
};

def enc_xor32(dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 32 && src.k == K.reg && op_size(src) == 32) {
        let r = rex(false, src.n, -1, dst.n);
        let b: [byte] = [49, modrm(3, src.n, dst.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "xor32 form" }
    }
};

def enc_alu_imm(op: str, dst: Operand, v: long) -> Encoded {
    // add/sub/cmp/xor/and/or $imm, %r64; cmp $imm, %r32
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "alu-imm dst" }
    } else if (op_size(dst) != 64) {
        if (op_size(dst) != 32) {
            { bytes: [], fix: [], err: "alu-imm dst" }
        } else {
            enc_alu_imm_go(op, dst, v)
        }
    } else {
        enc_alu_imm_go(op, dst, v)
    }
};

def enc_alu_imm_go(op: str, dst: Operand, v: long) -> Encoded {
    // (split from enc_alu_imm: the size gate above narrows; this body sees
    // only r64/r32 regs — no merged-shape reads.)
    enc_alu_imm_body(op, dst, v)
};

def enc_alu_imm_body(op: str, dst: Operand, v: long) -> Encoded {
    // (the size gate lives in enc_alu_imm; no gate here)
    let ext = 0;
    if (op == "sub") { ext = 5; }
    else if (op == "cmp") { ext = 7; }
    else if (op == "xor") { ext = 6; }
    else if (op == "and") { ext = 4; }
    else if (op == "or") { ext = 1; }
    let wide = op_size(dst) == 64;
    let r = rex(wide, -1, -1, dst.n);
    if (fits8(v)) {
        let prefix: [byte] = [131, modrm(3, ext, dst.n)];
        let imm: [byte] = [u8(v)];
        let b = concat(prefix, imm);
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        let prefix: [byte] = [129, modrm(3, ext, dst.n)];
        let b = concat(prefix, le32(v));
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_shift(mn: str, dst: Operand, cnt: Operand) -> Encoded {
    // shl/shr/sar $imm8 (0-63) or %cl, %r64: C1 /ext ib and D3 /ext, where
    // ext is shl 4, shr 5 (logical), sar 7 (arithmetic)
    let ext = 4;
    if (mn == "shr") { ext = 5; 0; }
    else if (mn == "sar") { ext = 7; 0; }
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: mn + " dst" }
    } else if (op_size(dst) != 64) {
        { bytes: [], fix: [], err: mn + " dst" }
    } else if (cnt.k == K.reg) {
        if (cnt.n == 1 && op_size(cnt) == 8) {
            let r = rex(true, -1, -1, dst.n);
            let b: [byte] = [211, modrm(3, ext, dst.n)];
            { bytes: with_rex(r, b), fix: [], err: "" }
        } else {
            { bytes: [], fix: [], err: mn + " count register is %cl" }
        }
    } else if (cnt.k == K.imm) {
        if (cnt.v < 0 || cnt.v > 63) {
            { bytes: [], fix: [], err: mn + " count range" }
        } else {
            let r = rex(true, -1, -1, dst.n);
            let prefix: [byte] = [193, modrm(3, ext, dst.n)];
            let imm: [byte] = [u8(cnt.v)];
            let b = concat(prefix, imm);
            { bytes: with_rex(r, b), fix: [], err: "" }
        }
    } else {
        { bytes: [], fix: [], err: mn + " count" }
    }
};

// ── SSE scalar-double encodings ────────────────────────────────────────
// Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
// comparison move them into %xmmN, so the rest of the backend (slots,
// pushes, calls) is unchanged.

def enc_sse_arith(mn: str, dst: Operand, src: Operand) -> Encoded {
    // F2 0F <op> /r  — addsd 58, subsd 5C, mulsd 59, divsd 5E
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "sse dst" }
    } else if (src.k != K.reg) {
        { bytes: [], fix: [], err: "sse src" }
    } else {
        let op = 88;
        if (mn == "subsd") { op = 92; 0; } else { 0; };
        if (mn == "mulsd") { op = 89; 0; } else { 0; };
        if (mn == "divsd") { op = 94; 0; } else { 0; };
        let r = rex(false, dst.n, -1, src.n);
        let tail: [byte] = [15, op, modrm(3, dst.n, src.n)];
        if (r < 0) {
            let prefix: [byte] = [242];
            { bytes: concat(prefix, tail), fix: [], err: "" }
        } else {
            let prefix: [byte] = [242, r];
            { bytes: concat(prefix, tail), fix: [], err: "" }
        }
    }
};

def enc_ucomisd(dst: Operand, src: Operand) -> Encoded {
    // 66 0F 2E /r
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "ucomisd dst" }
    } else if (src.k != K.reg) {
        { bytes: [], fix: [], err: "ucomisd src" }
    } else {
        let r = rex(false, dst.n, -1, src.n);
        let tail: [byte] = [15, 46, modrm(3, dst.n, src.n)];
        if (r < 0) {
            let prefix: [byte] = [102];
            { bytes: concat(prefix, tail), fix: [], err: "" }
        } else {
            let prefix: [byte] = [102, r];
            { bytes: concat(prefix, tail), fix: [], err: "" }
        }
    }
};

def enc_cvtsi2sd(dst: Operand, src: Operand) -> Encoded {
    // F2 REX.W 0F 2A /r  — cvtsi2sd %gpr, %xmm
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "cvtsi2sd dst" }
    } else if (src.k != K.reg) {
        { bytes: [], fix: [], err: "cvtsi2sd src" }
    } else {
        let r = rex(true, dst.n, -1, src.n);
        let prefix: [byte] = [242, r];
        let tail: [byte] = [15, 42, modrm(3, dst.n, src.n)];
        { bytes: concat(prefix, tail), fix: [], err: "" }
    }
};

def enc_cvttsd2si(dst: Operand, src: Operand) -> Encoded {
    // F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating)
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "cvttsd2si dst" }
    } else if (src.k != K.reg) {
        { bytes: [], fix: [], err: "cvttsd2si src" }
    } else {
        let r = rex(true, dst.n, -1, src.n);
        let prefix: [byte] = [242, r];
        let tail: [byte] = [15, 44, modrm(3, dst.n, src.n)];
        { bytes: concat(prefix, tail), fix: [], err: "" }
    }
};

def enc_movq(dst: Operand, src: Operand) -> Encoded {
    // 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
    // 66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr)
    if (dst.k != K.reg) {
        { bytes: [], fix: [], err: "movq dst" }
    } else if (src.k != K.reg) {
        { bytes: [], fix: [], err: "movq src" }
    } else if (op_size(dst) == 128) {
        // into an xmm: the xmm is the reg field, the gpr the rm field
        let r = rex(true, dst.n, -1, src.n);
        let prefix: [byte] = [102, r];
        let tail: [byte] = [15, 110, modrm(3, dst.n, src.n)];
        { bytes: concat(prefix, tail), fix: [], err: "" }
    } else {
        // out of an xmm: the xmm is still the reg field
        let r = rex(true, src.n, -1, dst.n);
        let prefix: [byte] = [102, r];
        let tail: [byte] = [15, 126, modrm(3, src.n, dst.n)];
        { bytes: concat(prefix, tail), fix: [], err: "" }
    }
};

def enc_imul(dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        let r = rex(true, dst.n, -1, src.n);
        let b: [byte] = [15, 175, modrm(3, dst.n, src.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "imul form" }
    }
};

def enc_unary(op: str, o: Operand) -> Encoded {
    if (o.k != K.reg) {
        { bytes: [], fix: [], err: "unary form" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "unary form" }
    } else {
        let ext = 3;
        let opc = 247;
        if (op == "idiv") { ext = 7; 0; }
        else if (op == "div") { ext = 6; 0; }
        else if (op == "not") { ext = 2; 0; }
        else if (op == "dec") { ext = 1; opc = 255; 0; }
        else if (op == "inc") { ext = 0; opc = 255; 0; }
        let r = rex(true, -1, -1, o.n);
        let b: [byte] = [opc, modrm(3, ext, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_jmp(o: Operand) -> Encoded {
    if (o.k != K.lbl) {
        { bytes: [], fix: [], err: "jmp target" }
    } else {
        let bytes: [byte] = [233, 0, 0, 0, 0];
        { bytes: bytes, fix: [fixup(1, "rel32", o.name, "")], err: "" }
    }
};

def enc_call(o: Operand) -> Encoded {
    if (o.k == K.ind) {
        // call *%reg — FF /2, used for closure code pointers.
        let r = rex(false, 0, -1, o.n);
        let b: [byte] = [255, modrm(3, 2, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else if (o.k != K.lbl) {
        { bytes: [], fix: [], err: "call target" }
    } else {
        let bytes: [byte] = [232, 0, 0, 0, 0];
        { bytes: bytes, fix: [fixup(1, "rel32", o.name, "")], err: "" }
    }
};

def enc_jcc(code: long, o: Operand) -> Encoded {
    if (o.k != K.lbl) {
        { bytes: [], fix: [], err: "jcc target" }
    } else {
        let bytes: [byte] = [15, code, 0, 0, 0, 0];
        { bytes: bytes, fix: [fixup(2, "rel32", o.name, "")], err: "" }
    }
};

def enc_setcc(code: long, o: Operand) -> Encoded {
    if (o.k != K.reg || op_size(o) != 8) {
        { bytes: [], fix: [], err: "setcc form" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b: [byte] = [15, code, modrm(3, 0, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_cmpb(v: long, m: Operand) -> Encoded {
    if (m.k != K.mem) {
        { bytes: [], fix: [], err: "cmpb form" }
    } else {
        let t = mem_tail(m, 7);
        let r = rex_rm(false, 7, m);
        let prefix: [byte] = [128, t.modrm];
        let imm: [byte] = [u8(v)];
        let b = concat(concat(prefix, t.extra), imm);
        enc_mem_result(r, b, t)
    }
};

def enc_movb_reg(dst: Operand, src: Operand) -> Encoded {
    // movb %r8 -> mem8 (single-byte stores for string data)
    if (dst.k == K.mem && src.k == K.reg && op_size(src) == 8) {
        let t = mem_tail(dst, src.n);
        let r = rex_rm(false, src.n, dst);
        let prefix: [byte] = [136, t.modrm];
        let b = concat(prefix, t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "movb reg form" }
    }
};

// ── mnemonic dispatch ──────────────────────────────────────────────────

def need1(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 1) { mn + " takes 1 operand" } else { "" }
};

def need2(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 2) { mn + " takes 2 operands" } else { "" }
};

def enc_insn(mn: str, ops: [Operand]) -> Encoded {
    if (mn == "push") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_push(ops[0]) }
    } else if (mn == "pop") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_pop(ops[0]) }
    } else if (mn == "mov") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_mov(ops[1], ops[0]) }
    } else if (mn == "movb") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else if (ops[0].k == K.imm) {
            enc_movb(ops[1], ops[0])
        } else {
            enc_movb_reg(ops[1], ops[0])
        }
    } else if (mn == "movzbq") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_movzbq(ops[1], ops[0]) }
    } else if (mn == "lea") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_lea(ops[1], ops[0]) }
    } else if (mn == "xchg") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_xchg(ops[0], ops[1]) }
    } else if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or" || mn == "test") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else {
            let dst = ops[1];
            let src = ops[0];
            if (src.k == K.imm) {
                if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or") {
                    enc_alu_imm(mn, dst, src.v)
                } else {
                    { bytes: [], fix: [], err: mn + " imm form" }
                }
            } else if (dst.k == K.reg && src.k == K.reg && mn == "xor" && op_size(dst) == 32 && op_size(src) == 32) {
                enc_xor32(dst, src)
            } else {
                enc_arith(mn, dst, src)
            }
        }
    } else if (mn == "shl" || mn == "shr" || mn == "sar") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_shift(mn, ops[1], ops[0]) }
    } else if (mn == "addsd" || mn == "subsd" || mn == "mulsd" || mn == "divsd") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_sse_arith(mn, ops[1], ops[0]) }
    } else if (mn == "ucomisd") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_ucomisd(ops[1], ops[0]) }
    } else if (mn == "cvtsi2sd") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_cvtsi2sd(ops[1], ops[0]) }
    } else if (mn == "cvttsd2si") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_cvttsd2si(ops[1], ops[0]) }
    } else if (mn == "movq") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_movq(ops[1], ops[0]) }
    } else if (mn == "imul") {
        let e = need2(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_imul(ops[1], ops[0]) }
    } else if (mn == "neg" || mn == "not" || mn == "idiv" || mn == "div" || mn == "dec" || mn == "inc") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_unary(mn, ops[0]) }
    } else if (mn == "jmp") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jmp(ops[0]) }
    } else if (mn == "call") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_call(ops[0]) }
    } else if (mn == "jz" || mn == "je") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(132, ops[0]) }
    } else if (mn == "jnz" || mn == "jne") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(133, ops[0]) }
    } else if (mn == "js") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(136, ops[0]) }
    } else if (mn == "jns") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(137, ops[0]) }
    } else if (mn == "jge") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(141, ops[0]) }
    } else if (mn == "jl") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(140, ops[0]) }
    } else if (mn == "jle") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(142, ops[0]) }
    } else if (mn == "jg") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(143, ops[0]) }
    } else if (mn == "jb") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_jcc(130, ops[0]) }
    } else if (mn == "setl") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(156, ops[0]) }
    } else if (mn == "setg") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(159, ops[0]) }
    } else if (mn == "setle") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(158, ops[0]) }
    } else if (mn == "setge") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(157, ops[0]) }
    } else if (mn == "sete") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(148, ops[0]) }
    } else if (mn == "setne") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(149, ops[0]) }
    } else if (mn == "seta") {
        // unsigned >: the correct condition after ucomisd (floats)
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(151, ops[0]) }
    } else if (mn == "setae") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(147, ops[0]) }
    } else if (mn == "setb") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(146, ops[0]) }
    } else if (mn == "setbe") {
        let e = need1(mn, ops);
        if (e != "") { { bytes: [], fix: [], err: e } } else { enc_setcc(150, ops[0]) }
    } else if (mn == "cmpb") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else if (ops[0].k != K.imm) {
            { bytes: [], fix: [], err: "cmpb needs imm" }
        } else {
            enc_cmpb(ops[0].v, ops[1])
        }
    } else if (mn == "cqo") {
        let bytes: [byte] = [72, 153];
        { bytes: bytes, fix: [], err: "" }
    } else if (mn == "syscall") {
        let bytes: [byte] = [15, 5];
        { bytes: bytes, fix: [], err: "" }
    } else if (mn == "ret") {
        let bytes: [byte] = [195];
        { bytes: bytes, fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "unknown mnemonic '" + mn + "'" }
    }
};

export { r64, reg_num, reg_size, enc_insn, concat, fixup, byte_of, le16, le32, le64 };
