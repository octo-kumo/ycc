// enc64.y — x86-64 instruction encoding for the native backend's subset.

// An operand, any of the forms above: every one carries every field (the
// ones its form does not use are 0 / "" / false), so a read is a load.
import tags from "./tags.y";
// Parsed x86 operands; the form selects which fields are meaningful.
type Operand = { k: long, n: long, size: long, v: long, a: str, b: str, name: str, base: long, idx: long, scale: long, disp: long, rip: bool, lbl: str };

// A register operand (see above).
type Reg = { k: long, n: long, size: long };

def r64(n: long) -> Reg { { k: K.reg, n: n, size: 64 } };
def r32(n: long) -> Reg { { k: K.reg, n: n, size: 32 } };
def r8(n: long) -> Reg { { k: K.reg, n: n, size: 8 } };

// Register number by AT&T name. Supports the registers our backend uses.
def reg_num(name: str) -> long {
    if (name in ["%rax", "%eax", "%ax", "%al"]) { 0 }
    else if (name in ["%rcx", "%ecx", "%cx", "%cl"]) { 1 }
    else if (name in ["%rdx", "%edx", "%dx", "%dl"]) { 2 }
    else if (name in ["%rbx", "%ebx", "%bx", "%bl"]) { 3 }
    else if (name == "%rsp" || name == "%esp" || name == "%sp") { 4 }
    else if (name == "%rbp" || name == "%ebp" || name == "%bp") { 5 }
    else if (name in ["%rsi", "%esi", "%si", "%sil"]) { 6 }
    else if (name in ["%rdi", "%edi", "%di", "%dil"]) { 7 }
    else if (name in ["%r8", "%r8d", "%r8w", "%r8b"]) { 8 }
    else if (name in ["%r9", "%r9d", "%r9w", "%r9b"]) { 9 }
    else if (name in ["%r10", "%r10d", "%r10w", "%r10b"]) { 10 }
    else if (name in ["%r11", "%r11d", "%r11w", "%r11b"]) { 11 }
    else if (name in ["%r12", "%r12d", "%r12w", "%r12b"]) { 12 }
    else if (name in ["%r13", "%r13d", "%r13w", "%r13b"]) { 13 }
    else if (name in ["%r14", "%r14d", "%r14w", "%r14b"]) { 14 }
    else if (name in ["%r15", "%r15d", "%r15w", "%r15b"]) { 15 }
    else if (name == "%xmm0") { 0 }
    else if (name == "%xmm1") { 1 }
    else if (name == "%xmm2") { 2 }
    else if (name == "%xmm3") { 3 }
    else if (name == "%xmm4") { 4 }
    else if (name == "%xmm5") { 5 }
    else if (name == "%xmm6") { 6 }
    else if (name == "%xmm7") { 7 }
    else if (name == "%xmm8") { 8 }
    else if (name == "%xmm9") { 9 }
    else if (name == "%xmm10") { 10 }
    else if (name == "%xmm11") { 11 }
    else if (name == "%xmm12") { 12 }
    else if (name == "%xmm13") { 13 }
    else if (name == "%xmm14") { 14 }
    else if (name == "%xmm15") { 15 }
    else { -1 }
};

def reg_size(name: str) -> long {
    let c = name[1];
    if (c == 'x') {
        // %xmmN: SSE register (size 128 marks the class apart from GPRs)
        128
    } else if (c == 'r') {
        // %r..: 64-bit, unless ends in d/w/b
        let last = name[len(name) - 1];
        if (last == 'd') { 32 } else if (last == 'w') { 16 } else if (last == 'b') { 8 } else { 64 }
    } else if (name in ["%ax", "%cx", "%dx", "%bx", "%sp", "%bp", "%si", "%di"]) {
        // The 16-bit GPR names, which the kernel's port I/O needs (%dx
        // carries a port number for inb/outb): a two-character name whose
        // second letter is one of the 16-bit mnemonics. `%xmm` above is
        // matched first, so this arm never sees an SSE name.
        16
    } else {
        // %e..: 32-bit; %..l / %..h legacy: 8-bit; %r.. handled above
        if (c == 'e') { 32 } else { 8 }
    }
};

// Safe size read: a non-register yields 0, whatever its `.size` holds.
def op_size(o: Operand) -> long {
    if (o.k == K.reg) { o.size } else { 0 }
};
def rex(w: bool, r: long, x: long, b: long) -> long {
    let v = 64;
    if (w) { v += 8; };
    if (r >= 8) { v += 4; };
    if (x >= 8) { v += 2; };
    if (b >= 8) { v++; };
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

// A little-endian run as its own array, for the callers outside the encoders
// (asm.y's .quad and its patcher). Inside an encoder use put_le32/put_le64,
// which write the same bytes through the cursor and allocate nothing. There is
// no put_le16: no encoder here writes a 16-bit field, so it had no caller.
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
    for j in 0..i {
        r *= 256;
    };
    r
};

def div_floor(v: long, d: long) -> long {
    // NOTE: Y division truncates toward zero (C semantics — native.y emits
    // `cqo; idiv` for `/`), so floor needs a correction when the remainder
    // is nonzero and the signs differ. Both engines truncate the same way,
    // so one correction serves them both.
    let q = v / d;
    if ((v - q * d) != 0) {
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

// ── the byte sink ───────────────────────────────────────────────────────
def scratch() -> [byte] {
    let out: [byte] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    out
};

def put(buf: [byte], at: long, v: long) -> long {
    buf[at] = v;
    at + 1
};

def put2(buf: [byte], at: long, a: long, b: long) -> long {
    buf[at] = a;
    buf[at + 1] = b;
    at + 2
};

def put3(buf: [byte], at: long, a: long, b: long, c: long) -> long {
    let n = put2(buf, at, a, b);
    buf[n] = c;
    n + 1
};

def put_le32(buf: [byte], at: long, v: long) -> long {
    put2(buf, (put2(buf, at, byte_of(v, 0), byte_of(v, 1))), byte_of(v, 2), byte_of(v, 3))
};

def put_le64(buf: [byte], at: long, v: long) -> long {
    put_le32(buf, (put_le32(buf, at, v)), div_floor(v, 4294967296))
};

// The REX prefix, or nothing: -1 means the form needs no prefix, and the
// cursor does not move.
def put_rex(buf: [byte], at: long, r: long) -> long {
    if (r < 0) { at } else { put(buf, at, r) }
};

type MemTail = { modrm: long, sib: long, ne: long, disp: long, rip_lbl: str };
def mem_tail(m: Operand, reg: long) -> MemTail {
    if (m.rip) {
        { modrm: modrm(0, reg, 5), sib: -1, ne: 0, disp: 0, rip_lbl: m.lbl }
    } else if (m.idx < 0) {
        // no index: [base+disp]. Low 101 (rbp/r13) needs at least disp8
        // (mod=00 would mean disp32-only); low 100 (rsp/r12) needs a SIB
        // byte whose base field is 100 — which is rsp, or r12 once REX.B
        // widens it (rex_rm sets that from m.base).
        if (m.base % 8 == 5) {
            if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 5), sib: -1, ne: 1, disp: m.disp, rip_lbl: "" }
            } else {
                { modrm: modrm(2, reg, 5), sib: -1, ne: 4, disp: m.disp, rip_lbl: "" }
            }
        } else if (m.base % 8 == 4) {
            // rsp/r12 as base: SIB byte required (index=none, base=rsp).
            // sib(1, 4, 4) = scale 00, index 100 (none), base 100 (rsp).
            if (m.disp == 0) {
                { modrm: modrm(0, reg, 4), sib: sib(1, 4, 4), ne: 0, disp: 0, rip_lbl: "" }
            } else if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 4), sib: sib(1, 4, 4), ne: 1, disp: m.disp, rip_lbl: "" }
            } else {
                { modrm: modrm(2, reg, 4), sib: sib(1, 4, 4), ne: 4, disp: m.disp, rip_lbl: "" }
            }
        } else if (m.disp == 0) {
            { modrm: modrm(0, reg, m.base), sib: -1, ne: 0, disp: 0, rip_lbl: "" }
        } else if (fits8(m.disp)) {
            { modrm: modrm(1, reg, m.base), sib: -1, ne: 1, disp: m.disp, rip_lbl: "" }
        } else {
            { modrm: modrm(2, reg, m.base), sib: -1, ne: 4, disp: m.disp, rip_lbl: "" }
        }
    } else {
        // SIB: [base + idx*scale + disp]. Low 101 needs explicit disp.
        let s = sib(m.scale, m.idx, m.base);
        if (m.base % 8 == 5) {
            if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 4), sib: s, ne: 1, disp: m.disp, rip_lbl: "" }
            } else {
                { modrm: modrm(2, reg, 4), sib: s, ne: 4, disp: m.disp, rip_lbl: "" }
            }
        } else if (m.disp == 0) {
            { modrm: modrm(0, reg, 4), sib: s, ne: 0, disp: 0, rip_lbl: "" }
        } else if (fits8(m.disp)) {
            { modrm: modrm(1, reg, 4), sib: s, ne: 1, disp: m.disp, rip_lbl: "" }
        } else {
            { modrm: modrm(2, reg, 4), sib: s, ne: 4, disp: m.disp, rip_lbl: "" }
        }
    }
};

// The tail's own bytes, after the ModRM the caller wrote.
def mem_tail_put(buf: [byte], at: long, t: MemTail) -> long {
    let n = at;
    if (t.sib >= 0) { n = put(buf, n, t.sib); };
    if (t.ne == 1) { n = put(buf, n, u8(t.disp)); }
    else if (t.ne == 4) { n = put_le32(buf, n, t.disp); };
    n
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

type Fixup = { off: long, kind: str, lbl: str, lbl2: str };
def fixup(at: long, kind: str, lbl: str, lbl2: str) -> Fixup {
    { off: at, kind: kind, lbl: lbl, lbl2: lbl2 }
};

// ── instruction encoders ───────────────────────────────────────────────
type Encoded = { at: long, fix: [Fixup], err: str, br: long };

def enc_err(at: long, msg: str) -> Encoded {
    { at: at, fix: [], err: msg, br: -1 }
};

def enc_ok(at: long, fx: [Fixup]) -> Encoded {
    { at: at, fix: fx, err: "", br: -1 }
};

// A branch, which is what `br` names.
def enc_br(at: long, fx: [Fixup], br: long) -> Encoded {
    { at: at, fix: fx, err: "", br: br }
};

// A label operand, for re-encoding a branch whose target is already known (the
// item's fixup carries the name).
def lbl_op(name: str) -> Operand {
    { k: K.lbl, n: 0, size: 0, v: 0, a: "", b: "", name: name, base: -1, idx: -1,
        scale: 1, disp: 0, rip: false, lbl: "" }
};

// The long (rel32) form of a branch, for asm_relax's grower pass: `br` is what
// the item recorded, `lbl` what its fixup names.
def enc_branch_long(buf: [byte], at: long, br: long, lbl: str) -> Encoded {
    if (br == 0) { enc_jmp(buf, at, lbl_op(lbl), true) }
    else { enc_jcc(buf, at, br, lbl_op(lbl), true) }
};

def enc_push(buf: [byte], at: long, o: Operand) -> Encoded {
    if (o.k == K.imm) {
        // 6A ib for a byte's worth, 68 id otherwise; either is sign-extended
        if (fits8(o.v)) {
            enc_ok(put2(buf, at, 106, o.v & 255), [])
        } else if (o.v >= -2147483648 && o.v <= 2147483647) {
            enc_ok(put_le32(buf, put(buf, at, 104), o.v), [])
        } else {
            enc_err(at, "push needs imm32")
        }
    } else if (o.k == K.mem) {
        // FF /6, without REX.W: the operand is 64 bits already
        let t = mem_tail(o, 6);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(false, 6, o))), 255, t.modrm)), t), t)
    } else if (o.k != K.reg) {
        enc_err(at, "push needs r64")
    } else if (op_size(o) != 64) {
        enc_err(at, "push needs r64")
    } else {
        enc_ok(put(buf, (put_rex(buf, at, rex(false, -1, -1, o.n))), 80 + (o.n % 8)), [])
    }
};

def enc_pop(buf: [byte], at: long, o: Operand) -> Encoded {
    if (o.k != K.reg) {
        enc_err(at, "pop needs r64")
    } else if (op_size(o) != 64) {
        enc_err(at, "pop needs r64")
    } else {
        enc_ok(put(buf, (put_rex(buf, at, rex(false, -1, -1, o.n))), 88 + (o.n % 8)), [])
    }
};

def enc_mov(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && src.k == K.reg) {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            enc_ok(put2(buf, (put_rex(buf, at, rex(true, src.n, -1, dst.n))), 137, modrm(3, src.n, dst.n)), [])
        } else {
            enc_err(at, "mov reg,reg size mix")
        }
    } else if (dst.k == K.reg && src.k == K.imm) {
        if (op_size(dst) == 64) {
            if (src.v >= 0 && src.v <= 4294967295) {
                // B8+r id: the 32-bit move zero-extends, so a value that fits
                // unsigned in 32 bits costs five bytes rather than C7's seven
                enc_ok(put_le32(buf, (put(buf, (put_rex(buf, at, rex(false, -1, -1, dst.n))), 184 + (dst.n % 8))), src.v), [])
            } else if (src.v >= -2147483648 && src.v <= 2147483647) {
                enc_ok(put_le32(buf, (put2(buf, (put_rex(buf, at, rex(true, -1, -1, dst.n))), 199, modrm(3, 0, dst.n))), src.v), [])
            } else {
                enc_ok(put_le64(buf, (put(buf, (put_rex(buf, at, rex(true, -1, -1, dst.n))), 184 + (dst.n % 8))), src.v), [])
            }
        } else if (op_size(dst) == 32) {
            enc_ok(put_le32(buf, (put(buf, (put_rex(buf, at, rex(false, -1, -1, dst.n))), 184 + (dst.n % 8))), src.v), [])
        } else {
            enc_err(at, "mov imm size")
        }
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.diff) {
        let r = rex(true, -1, -1, dst.n);
        let m = put2(buf, (put_rex(buf, at, r)), 199, modrm(3, 0, dst.n));
        // the four bytes are placeholders; pass 2 writes src.a - src.b
        let q = put_le32(buf, m, 0);
        let off = 3;
        if (r < 0) { off = 2; };
        enc_ok(q, [fixup(at + off, "imm32diff", src.a, src.b)])
    } else if (dst.k == K.reg && src.k == K.fs && op_size(dst) == 64) {
        // mov %seg:disp32, r64: the segment prefix (0x64 %fs, 0x65 %gs -- the
        // operand's `n`), REX.W, 8B, a SIB with no base and no index (an
        // absolute disp32)
        enc_ok(put_le32(buf, (put(buf, (put2(buf, (put(buf, (put(buf, at, 100 + src.n)), rex(true, dst.n, -1, -1))), 139, modrm(0, dst.n, 4))), 37)), src.disp), [])
    } else if (dst.k == K.reg && src.k == K.mem) {
        if (op_size(dst) == 64) {
            let t = mem_tail(src, dst.n);
            enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, dst.n, src))), 139, t.modrm)), t), t)
        } else {
            enc_err(at, "mov r,mem size")
        }
    } else if (dst.k == K.mem && src.k == K.imm) {
        // mov $imm32, mem (length/cap stores)
        let t = mem_tail(dst, 0);
        enc_mem_imm_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, 0, dst))), 199, t.modrm)), t), t, src.v, true)
    } else if (dst.k == K.mem && src.k == K.reg) {
        if (op_size(src) == 64) {
            let t = mem_tail(dst, src.n);
            enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, src.n, dst))), 137, t.modrm)), t), t)
        } else if (op_size(src) == 8) {
            let t = mem_tail(dst, src.n);
            enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(false, src.n, dst))), 136, t.modrm)), t), t)
        } else {
            enc_err(at, "mov mem,reg size")
        }
    } else {
        enc_err(at, "mov form")
    }
};
// xchg r64, mem (either order): REX.W 87 /r, locked by the processor
// (the threads' mutexes).
def enc_xchg(buf: [byte], at: long, a: Operand, b: Operand) -> Encoded {
    let reg = a;
    let mem = b;
    if (a.k == K.mem) {
        reg = b;
        mem = a;
    };
    if (reg.k != K.reg || mem.k != K.mem || op_size(reg) != 64) {
        enc_err(at, "xchg form")
    } else {
        let t = mem_tail(mem, reg.n);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, reg.n, mem))), 135, t.modrm)), t), t)
    }
};

def enc_mem_result(buf: [byte], at: long, t: MemTail) -> Encoded {
    if (t.modrm < 0) {
        enc_err(at, "bad memory form")
    } else if (t.rip_lbl == "") {
        enc_ok(at, [])
    } else {
        enc_ok(put_le32(buf, at, 0), [fixup(at, "rip32", t.rip_lbl, "")])
    }
};

def enc_mem_imm_result(buf: [byte], at: long, t: MemTail, v: long, wide: bool) -> Encoded {
    if (t.modrm < 0) {
        enc_err(at, "bad memory form")
    } else {
        let n = at;
        let fx: [Fixup] = [];
        if (t.rip_lbl != "") {
            fx += fixup(at, "rip32", t.rip_lbl, "");
            n = put_le32(buf, n, 0);
        };
        if (wide) { enc_ok(put_le32(buf, n, v), fx) }
        else { enc_ok(put(buf, n, u8(v)), fx) }
    }
};

def enc_movb(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // movb $imm8, mem
    if (dst.k != K.mem) {
        enc_err(at, "movb form")
    } else if (src.k != K.imm) {
        enc_err(at, "movb form")
    } else {
        enc_movb_imm(buf, at, dst, src)
    }
};

def enc_movb_imm(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // (split: shape gate above narrows; this body sees mem/imm only.)
    if (src.v < -128) {
        enc_err(at, "movb imm range")
    } else if (src.v > 127) {
        enc_err(at, "movb imm range")
    } else {
        let t = mem_tail(dst, 0);
        enc_mem_imm_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(false, 0, dst))), 198, t.modrm)), t), t, src.v, false)
    }
};

def enc_movzbq(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 8) {
        enc_ok(put3(buf, (put_rex(buf, at, rex(true, dst.n, -1, src.n))), 15, 182, modrm(3, dst.n, src.n)), [])
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        // movzbq mem8 -> r64 (single-byte loads for string data)
        let t = mem_tail(src, dst.n);
        enc_mem_result(buf, mem_tail_put(buf, (put3(buf, (put_rex(buf, at, rex_rm(true, dst.n, src))), 15, 182, t.modrm)), t), t)
    } else {
        enc_err(at, "movzbq form")
    }
};

// Loads that widen into a 64-bit register: movzwq movsbq movswq movslq and the
// 32-bit `movl` (zero-extends). `w` is REX.W, `esc` a 0x0F opcode prefix. The
// source is memory or a register of the narrow width (the size field is not
// checked: the emitter owns that).
def enc_ldx(buf: [byte], at: long, dst: Operand, src: Operand, w: bool, esc: bool, opc: long) -> Encoded {
    if (dst.k != K.reg) {
        enc_err(at, "load-extend form")
    } else if (src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        let n = put_rex(buf, at, rex_rm(w, dst.n, src));
        if (esc) { n = put2(buf, n, 15, opc); } else { n = put(buf, n, opc); };
        enc_mem_result(buf, mem_tail_put(buf, put(buf, n, t.modrm), t), t)
    } else if (src.k == K.reg) {
        let n = put_rex(buf, at, rex(w, dst.n, -1, src.n));
        if (esc) { n = put2(buf, n, 15, opc); } else { n = put(buf, n, opc); };
        enc_ok(put(buf, n, modrm(3, dst.n, src.n)), [])
    } else {
        enc_err(at, "load-extend form")
    }
};

// movw / movl: store the low 16 / 32 bits of a register to memory.
def enc_stx(buf: [byte], at: long, dst: Operand, src: Operand, pre66: bool) -> Encoded {
    if (dst.k == K.mem && src.k == K.reg) {
        let t = mem_tail(dst, src.n);
        let n = at;
        if (pre66) { n = put(buf, n, 102); };
        n = put_rex(buf, n, rex_rm(false, src.n, dst));
        enc_mem_result(buf, mem_tail_put(buf, put2(buf, n, 137, t.modrm), t), t)
    } else {
        enc_err(at, "store form")
    }
};

// bswapq / bswapl: byte-reverse a register (the big-endian field types).
def enc_bswap(buf: [byte], at: long, r: Operand, w: bool) -> Encoded {
    if (r.k != K.reg) {
        enc_err(at, "bswap form")
    } else {
        enc_ok(put2(buf, (put_rex(buf, at, rex(w, 0, -1, r.n))), 15, 200 + r.n % 8), [])
    }
};

def enc_lea(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, dst.n, src))), 141, t.modrm)), t), t)
    } else {
        enc_err(at, "lea form")
    }
};

def enc_arith(buf: [byte], at: long, op: str, dst: Operand, src: Operand) -> Encoded {
    // op: add/sub/xor/and/or/cmp/test; r64,r64 only here
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        let base = 1;
        if (op == "sub") { base = 41; }
        else if (op == "xor") { base = 49; }
        else if (op == "and") { base = 33; }
        else if (op == "or") { base = 9; }
        else if (op == "cmp") { base = 57; }
        else if (op == "test") { base = 133; }
        enc_ok(put2(buf, (put_rex(buf, at, rex(true, src.n, -1, dst.n))), base, modrm(3, src.n, dst.n)), [])
    } else if (op == "cmp" && dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        // cmp mem, r64 (3B /r): a bounds check against the length in memory
        let t = mem_tail(src, dst.n);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, dst.n, src))), 59, t.modrm)), t), t)
    } else {
        enc_err(at, "arith reg form")
    }
};

def enc_test32(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (op_size(dst) == 32 && op_size(src) == 32) {
        enc_ok(put2(buf, (put_rex(buf, at, rex(false, src.n, -1, dst.n))), 133, modrm(3, src.n, dst.n)), [])
    } else {
        enc_err(at, "test32 form")
    }
};

def enc_xor32(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 32 && src.k == K.reg && op_size(src) == 32) {
        enc_ok(put2(buf, (put_rex(buf, at, rex(false, src.n, -1, dst.n))), 49, modrm(3, src.n, dst.n)), [])
    } else {
        enc_err(at, "xor32 form")
    }
};

// The /ext of the ALU group (add is 0): the register and the memory forms are
// the same instruction with a different ModRM, so they share the table.
def alu_ext(op: str) -> long {
    if (op == "sub") { 5 }
    else if (op == "cmp") { 7 }
    else if (op == "xor") { 6 }
    else if (op == "and") { 4 }
    else if (op == "or") { 1 }
    else { 0 }
};

def enc_alu_imm(buf: [byte], at: long, op: str, dst: Operand, v: long) -> Encoded {
    // add/sub/cmp/xor/and/or $imm, %r64; cmp $imm, %r32; and $imm, mem
    if (dst.k == K.mem) {
        enc_alu_imm_mem(buf, at, op, dst, v)
    } else if (dst.k != K.reg) {
        enc_err(at, "alu-imm dst")
    } else if (op_size(dst) != 64) {
        if (op_size(dst) != 32) {
            enc_err(at, "alu-imm dst")
        } else {
            enc_alu_imm_go(buf, at, op, dst, v)
        }
    } else {
        enc_alu_imm_go(buf, at, op, dst, v)
    }
};

def enc_alu_imm_mem(buf: [byte], at: long, op: str, dst: Operand, v: long) -> Encoded {
    let ext = alu_ext(op);
    if (fits8(v)) {
        let t = mem_tail(dst, ext);
        enc_mem_imm_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, ext, dst))), 131, t.modrm)), t), t, v, false)
    } else if (v < -2147483648 || v > 2147483647) {
        // the same door the register form has (see enc_alu_imm_body)
        enc_err(at, "an immediate does not fit in 32 bits")
    } else {
        let t = mem_tail(dst, ext);
        enc_mem_imm_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, ext, dst))), 129, t.modrm)), t), t, v, true)
    }
};

def enc_alu_imm_go(buf: [byte], at: long, op: str, dst: Operand, v: long) -> Encoded {
    // (split from enc_alu_imm: the size gate above narrows; this body sees
    // only r64/r32 regs — no merged-shape reads.)
    enc_alu_imm_body(buf, at, op, dst, v)
};

def enc_alu_imm_body(buf: [byte], at: long, op: str, dst: Operand, v: long) -> Encoded {
    // (the size gate lives in enc_alu_imm; this one is on the value)
    let ext = alu_ext(op);
    let r = rex((op_size(dst) == 64), -1, -1, dst.n);
    if (fits8(v)) {
        enc_ok(put(buf, (put2(buf, (put_rex(buf, at, r)), 131, modrm(3, ext, dst.n))), u8(v)), [])
    } else if (v < -2147483648 || v > 2147483647) {
        enc_err(at, "an immediate does not fit in 32 bits")
    } else {
        enc_ok(put_le32(buf, (put2(buf, (put_rex(buf, at, r)), 129, modrm(3, ext, dst.n))), v), [])
    }
};

def enc_test_imm(buf: [byte], at: long, dst: Operand, v: long) -> Encoded {
    // (split: this is the shape gate; the body sees a 32- or 64-bit register
    // and no merged-shape read, so it reads dst.n straight.)
    if (dst.k != K.reg) {
        enc_err(at, "test imm dst")
    } else if (op_size(dst) != 64 && op_size(dst) != 32) {
        enc_err(at, "test imm dst")
    } else {
        enc_test_imm_body(buf, at, dst, v)
    }
};

def enc_test_imm_body(buf: [byte], at: long, dst: Operand, v: long) -> Encoded {
    // (the shape gate lives in enc_test_imm; this one is on the value)
    let r = rex(op_size(dst) == 64, -1, -1, dst.n);
    if (v < -2147483648 || v > 2147483647) {
        // the same door enc_alu_imm_body has, and for the same reason: F7 takes
        // a sign-extended imm32 and put_le32 would keep the low four bytes.
        enc_err(at, "an immediate does not fit in 32 bits")
    } else {
        enc_ok(put_le32(buf, (put2(buf, (put_rex(buf, at, r)), 247, modrm(3, 0, dst.n))), v), [])
    }
};

def enc_shift(buf: [byte], at: long, mn: str, dst: Operand, cnt: Operand) -> Encoded {
    // shl/shr/sar $imm8 (0-63) or %cl, %r64: C1 /ext ib and D3 /ext, where
    // ext is shl 4, shr 5 (logical), sar 7 (arithmetic)
    let ext = 4;
    if (mn == "shr") { ext = 5; }
    else if (mn == "sar") { ext = 7; }
    if (dst.k != K.reg) {
        enc_err(at, mn + " dst")
    } else if (op_size(dst) != 64) {
        enc_err(at, mn + " dst")
    } else if (cnt.k == K.reg) {
        if (cnt.n == 1 && op_size(cnt) == 8) {
            enc_ok(put2(buf, (put_rex(buf, at, rex(true, -1, -1, dst.n))), 211, modrm(3, ext, dst.n)), [])
        } else {
            enc_err(at, mn + " count register is %cl")
        }
    } else if (cnt.k == K.imm) {
        if (cnt.v < 0 || cnt.v > 63) {
            enc_err(at, mn + " count range")
        } else {
            enc_ok(put(buf, (put2(buf, (put_rex(buf, at, rex(true, -1, -1, dst.n))), 193, modrm(3, ext, dst.n))), u8(cnt.v)), [])
        }
    } else {
        enc_err(at, mn + " count")
    }
};

// ── SSE scalar-double encodings ────────────────────────────────────────
// Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
// comparison move them into %xmmN, so the rest of the backend (slots,
// pushes, calls) is unchanged.

def sse_op(mn: str) -> long {
    // addsd 58, subsd 5C, mulsd 59, divsd 5E
    let op = 88;
    if (mn == "subsd") { op = 92; }
    if (mn == "mulsd") { op = 89; }
    if (mn == "divsd") { op = 94; }
    op
};

def enc_sse_arith(buf: [byte], at: long, mn: str, dst: Operand, src: Operand) -> Encoded {
    if (dst.k != K.reg || op_size(dst) != 128) {
        enc_err(at, "sse dst")
    } else if (src.k == K.reg) {
        enc_ok(put3(buf, (put_rex(buf, (put(buf, at, 242)), rex(false, dst.n, -1, src.n))), 15, sse_op(mn), modrm(3, dst.n, src.n)), [])
    } else if (src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        enc_mem_result(buf, mem_tail_put(buf, put(buf, (put2(buf, (put_rex(buf, put(buf, at, 242), rex_rm(false, dst.n, src))), 15, sse_op(mn))), t.modrm), t), t)
    } else {
        enc_err(at, "sse src")
    }
};

// F2 0F 10 /r loads into an xmm (or moves xmm to xmm); F2 0F 11 /r stores.
// There is no REX.W: the value is eight bytes wide either way.
def enc_movsd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 128) {
        if (src.k == K.reg && op_size(src) == 128) {
            enc_ok(put3(buf, (put_rex(buf, (put(buf, at, 242)), rex(false, dst.n, -1, src.n))), 15, 16, modrm(3, dst.n, src.n)), [])
        } else if (src.k == K.mem) {
            let t = mem_tail(src, dst.n);
            enc_mem_result(buf, mem_tail_put(buf, put(buf, (put2(buf, (put_rex(buf, put(buf, at, 242), rex_rm(false, dst.n, src))), 15, 16)), t.modrm), t), t)
        } else {
            enc_err(at, "movsd src")
        }
    } else if (dst.k == K.mem && src.k == K.reg && op_size(src) == 128) {
        let t = mem_tail(dst, src.n);
        enc_mem_result(buf, mem_tail_put(buf, put(buf, (put2(buf, (put_rex(buf, put(buf, at, 242), rex_rm(false, src.n, dst))), 15, 17)), t.modrm), t), t)
    } else {
        enc_err(at, "movsd form")
    }
};

def enc_ucomisd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // 66 0F 2E /r, with the source an xmm or memory. The memory form is what a
    // float kernel tests against -- `ucomisd tab+0(%rip), %xmm0` is "is the
    // argument above exp_hi" -- and it is the comparison whose UNORDERED result
    // (PF set) is how every float function first asks "was one of them a NaN".
    if (dst.k != K.reg || op_size(dst) != 128) {
        enc_err(at, "ucomisd dst")
    } else if (src.k == K.reg) {
        enc_ok(put3(buf, (put_rex(buf, (put(buf, at, 102)), rex(false, dst.n, -1, src.n))), 15, 46, modrm(3, dst.n, src.n)), [])
    } else if (src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        enc_mem_result(buf, mem_tail_put(buf, put(buf, (put2(buf, (put_rex(buf, put(buf, at, 102), rex_rm(false, dst.n, src))), 15, 46)), t.modrm), t), t)
    } else {
        enc_err(at, "ucomisd src")
    }
};

def enc_sqrtsd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // F2 0F 51 /r  — sqrtsd %xmm, %xmm
    if (dst.k != K.reg) {
        enc_err(at, "sqrtsd dst")
    } else if (src.k != K.reg) {
        enc_err(at, "sqrtsd src")
    } else {
        enc_ok(put3(buf, (put_rex(buf, (put(buf, at, 242)), rex(false, dst.n, -1, src.n))), 15, 81, modrm(3, dst.n, src.n)), [])
    }
};

def enc_cvtsi2sd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k != K.reg) {
        enc_err(at, "cvtsi2sd dst")
    } else if (src.k != K.reg) {
        enc_err(at, "cvtsi2sd src")
    } else {
        enc_ok(put3(buf, (put(buf, (put(buf, at, 242)), rex(true, dst.n, -1, src.n))), 15, 42, modrm(3, dst.n, src.n)), [])
    }
};

def enc_cvttsd2si(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating). F2 for the
    // reason above: F3 here would be CVTTSS2SI.
    if (dst.k != K.reg) {
        enc_err(at, "cvttsd2si dst")
    } else if (src.k != K.reg) {
        enc_err(at, "cvttsd2si src")
    } else {
        enc_ok(put3(buf, (put(buf, (put(buf, at, 242)), rex(true, dst.n, -1, src.n))), 15, 44, modrm(3, dst.n, src.n)), [])
    }
};

def enc_movq(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
    // 66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr)
    if (dst.k != K.reg) {
        enc_err(at, "movq dst")
    } else if (src.k != K.reg) {
        enc_err(at, "movq src")
    } else if (op_size(dst) == 128 && op_size(src) == 128) {
        enc_ok(put3(buf, (put_rex(buf, (put(buf, at, 243)), rex(false, dst.n, -1, src.n))), 15, 126, modrm(3, dst.n, src.n)), [])
    } else if (op_size(dst) == 128) {
        // into an xmm: the xmm is the reg field, the gpr the rm field
        enc_ok(put3(buf, (put(buf, (put(buf, at, 102)), rex(true, dst.n, -1, src.n))), 15, 110, modrm(3, dst.n, src.n)), [])
    } else if (op_size(src) != 128) {
        // Neither side is an xmm, so this is not a float move at all. Taking
        // it as one would quietly read an SSE register and write a GPR (or the
        // other way round) where the source said a register move -- a silent
        // miscompile, and this assembler's one rule is to be loud instead.
        enc_err(at, "movq needs an xmm register")
    } else {
        // out of an xmm: 66 REX.W 0F 7E /r is reg=xmm, rm=r/m64
        enc_ok(put3(buf, (put(buf, (put(buf, at, 102)), rex(true, src.n, -1, dst.n))), 15, 126, modrm(3, src.n, dst.n)), [])
    }
};

def enc_imul(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        enc_ok(put3(buf, (put_rex(buf, at, rex(true, dst.n, -1, src.n))), 15, 175, modrm(3, dst.n, src.n)), [])
    } else {
        enc_err(at, "imul form")
    }
};

// bsr r64, r64 (REX.W 0F BD /r): the index of the highest set bit. The
// collector's resolve finds a candidate's block as the nearest start bit at or
// below it, a word of the start map at a time.
def enc_bsr(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        enc_ok(put3(buf, (put_rex(buf, at, rex(true, dst.n, -1, src.n))), 15, 189, modrm(3, dst.n, src.n)), [])
    } else {
        enc_err(at, "bsr form")
    }
};

def enc_unary(buf: [byte], at: long, op: str, o: Operand) -> Encoded {
    if (o.k == K.mem) {
        enc_unary_mem(buf, at, op, o)
    } else if (o.k != K.reg) {
        enc_err(at, "unary form")
    } else if (op_size(o) != 64) {
        enc_err(at, "unary form")
    } else {
        let ext = 3;
        let opc = 247;
        if (op == "idiv") { ext = 7; }
        else if (op == "div") { ext = 6; }
        else if (op == "not") { ext = 2; }
        else if (op == "dec") { ext = 1; opc = 255; }
        else if (op == "inc") { ext = 0; opc = 255; }
        enc_ok(put2(buf, (put_rex(buf, at, rex(true, -1, -1, o.n))), opc, modrm(3, ext, o.n)), [])
    }
};

def enc_unary_mem(buf: [byte], at: long, op: str, o: Operand) -> Encoded {
    let ext = 0;
    let opc = 255;
    if (op == "dec") { ext = 1; }
    else if (op == "not") { ext = 2; opc = 247; };
    if (op in ["inc", "dec", "not"]) {
        let t = mem_tail(o, ext);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(true, ext, o))), opc, t.modrm)), t), t)
    } else {
        enc_err(at, "unary form")
    }
};

def enc_jmp(buf: [byte], at: long, o: Operand, lng: bool) -> Encoded {
    if (o.k == K.ind) {
        enc_ok(put2(buf, (put_rex(buf, at, rex(false, 0, -1, o.n))), 255, modrm(3, 4, o.n)), [])
    } else if (o.k != K.lbl) {
        enc_err(at, "jmp target")
    } else if (lng) {
        enc_br((put_le32(buf, (put(buf, at, 233)), 0)), [fixup(at + 1, "rel32", o.name, "")], 0)
    } else {
        enc_br(put(buf, (put(buf, at, 235)), 0), [fixup(at + 1, "rel8", o.name, "")], 0)
    }
};

def enc_call(buf: [byte], at: long, o: Operand) -> Encoded {
    if (o.k == K.ind) {
        // call *%reg — FF /2, used for closure code pointers.
        enc_ok(put2(buf, (put_rex(buf, at, rex(false, 0, -1, o.n))), 255, modrm(3, 2, o.n)), [])
    } else if (o.k != K.lbl) {
        enc_err(at, "call target")
    } else {
        enc_ok((put_le32(buf, (put(buf, at, 232)), 0)), [fixup(at + 1, "rel32", o.name, "")])
    }
};

def enc_jcc(buf: [byte], at: long, code: long, o: Operand, lng: bool) -> Encoded {
    if (o.k != K.lbl) {
        enc_err(at, "jcc target")
    } else if (lng) {
        enc_br((put_le32(buf, (put2(buf, at, 15, code)), 0)), [fixup(at + 2, "rel32", o.name, "")], code)
    } else {
        // the short form's opcode is the long form's 16 bytes lower
        enc_br(put(buf, (put(buf, at, code - 16)), 0), [fixup(at + 1, "rel8", o.name, "")], code)
    }
};

def enc_setcc(buf: [byte], at: long, code: long, o: Operand) -> Encoded {
    if (o.k != K.reg || op_size(o) != 8) {
        enc_err(at, "setcc form")
    } else {
        enc_ok(put3(buf, (put_rex(buf, at, rex(false, -1, -1, o.n))), 15, code, modrm(3, 0, o.n)), [])
    }
};

// cmpb $imm8, mem8. No emitter produces this form (the byte comparisons the
// backend needs all go through movzbq), but the assembler accepts it, so it
// goes through enc_mem_imm_result like the other immediate forms: the rip
// placeholder belongs between the ModRM and the immediate, not after it.
def enc_cmpb(buf: [byte], at: long, v: long, m: Operand) -> Encoded {
    if (m.k != K.mem) {
        enc_err(at, "cmpb form")
    } else {
        let t = mem_tail(m, 7);
        enc_mem_imm_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(false, 7, m))), 128, t.modrm)), t), t, v, false)
    }
};

def enc_movb_reg(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // movb %r8 -> mem8 (single-byte stores for string data)
    if (dst.k == K.mem && src.k == K.reg && op_size(src) == 8) {
        let t = mem_tail(dst, src.n);
        enc_mem_result(buf, mem_tail_put(buf, (put2(buf, (put_rex(buf, at, rex_rm(false, src.n, dst))), 136, t.modrm)), t), t)
    } else {
        enc_err(at, "movb reg form")
    }
};

// ── mnemonic dispatch ──────────────────────────────────────────────────

def need1(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 1) { mn + " takes 1 operand" } else { "" }
};

def need2(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 2) { mn + " takes 2 operands" } else { "" }
};

def enc_dispatch_movb(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    let e = need2(mn, ops);
    if (e != "") {
        enc_err(at, e)
    } else if (ops[0].k == K.imm) {
        enc_movb(buf, at, ops[1], ops[0])
    } else {
        enc_movb_reg(buf, at, ops[1], ops[0])
    }
};

def enc_dispatch_movl(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    let e = need2(mn, ops);
    if (e != "") {
        enc_err(at, e)
    } else if (ops[1].k == K.mem) {
        enc_stx(buf, at, ops[1], ops[0], false)
    } else {
        enc_ldx(buf, at, ops[1], ops[0], false, false, 139)
    }
};

def enc_dispatch_add(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    let e = need2(mn, ops);
    if (e != "") {
        enc_err(at, e)
    } else {
        let dst = ops[1];
        let src = ops[0];
        if (src.k == K.imm) {
            if (mn in ["add", "sub", "cmp", "xor", "and", "or"]) {
                enc_alu_imm(buf, at, mn, dst, src.v)
            } else {
                enc_test_imm(buf, at, dst, src.v)
            }
        } else if (dst.k == K.reg && src.k == K.reg && mn == "xor" && op_size(dst) == 32 && op_size(src) == 32) {
            enc_xor32(buf, at, dst, src)
        } else if (dst.k == K.reg && src.k == K.reg && mn == "test" && op_size(dst) == 32 && op_size(src) == 32) {
            enc_test32(buf, at, dst, src)
        } else {
            enc_arith(buf, at, mn, dst, src)
        }
    }
};

def enc_dispatch_cmpb(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    let e = need2(mn, ops);
    if (e != "") {
        enc_err(at, e)
    } else if (ops[0].k != K.imm) {
        enc_err(at, "cmpb needs imm")
    } else {
        enc_cmpb(buf, at, ops[0].v, ops[1])
    }
};

def enc_dispatch_ret(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    if (len(ops) == 1 && ops[0].k == K.imm) {
        enc_ok(put3(buf, at, 194, ops[0].v & 255, (ops[0].v >> 8) & 255), [])
    } else { enc_ok(put(buf, at, 195), []) }
};
import encshapes from "./encoder_shapes.y";
// ── the kernel's own instructions ───────────────────────────────────────
def enc_outb(buf: [byte], at: long, src: Operand, port: Operand) -> Encoded {
    // outb %al, %dx (EE) or outb %al, $imm8 (E6 ib). A port above 255 -- the
    // UART's 0x3F8, say -- has only the %dx form.
    if (src.k != K.reg || op_size(src) != 8 || src.n != 0) {
        enc_err(at, "outb needs %al as its source")
    } else if (port.k == K.reg && op_size(port) == 16 && port.n == 2) {
        enc_ok(put(buf, at, 238), [])
    } else if (port.k == K.imm && port.v >= 0 && port.v <= 255) {
        enc_ok(put(buf, (put(buf, at, 230)), port.v), [])
    } else {
        enc_err(at, "outb port is $imm8 or %dx")
    }
};

def enc_inb(buf: [byte], at: long, port: Operand, dst: Operand) -> Encoded {
    // inb %dx, %al (EC) or inb $imm8, %al (E4 ib).
    if (dst.k != K.reg || op_size(dst) != 8 || dst.n != 0) {
        enc_err(at, "inb needs %al as its destination")
    } else if (port.k == K.reg && op_size(port) == 16 && port.n == 2) {
        enc_ok(put(buf, at, 236), [])
    } else if (port.k == K.imm && port.v >= 0 && port.v <= 255) {
        enc_ok(put(buf, (put(buf, at, 228)), port.v), [])
    } else {
        enc_err(at, "inb port is $imm8 or %dx")
    }
};

def enc_lidt(buf: [byte], at: long, o: Operand) -> Encoded {
    // 0F 01 /3, the operand being the 10-byte descriptor's address.
    if (o.k != K.mem) {
        enc_err(at, "lidt needs a memory operand")
    } else {
        let t = mem_tail(o, 3);
        enc_mem_result(buf, mem_tail_put(buf, put3(buf, (put_rex(buf, at, rex_rm(false, 3, o))), 15, 1, t.modrm), t), t)
    }
};

// The types are exported too: enc_insn and enc_form take [Operand] and return
// Encoded, so a caller that wants to name either needs the name.
export { Operand, Fixup, Encoded, MemTail, r64, reg_num, reg_size, enc_insn,
    enc_form, enc_branch_long, fixup, byte_of, scratch, le16, le32, le64 };
