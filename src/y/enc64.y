// enc64.y — x86-64 instruction encoding for the native backend's subset.
// Operands use the assembler's parsed forms (asm.y parse_operand):
//   {k:K.reg, n, size}      n = 0-15, size = 64/32/8 (128 = an xmm)
//   {k:K.imm, v}            signed long
//   {k:K.mem, base, idx, scale, disp, rip, lbl}  rip: bool (lbl valid),
//     base/idx: reg numbers (-1 = none), scale 1/2/4/8, disp long
//   {k:K.lbl, name}         code label (jumps/calls)
//   {k:K.ind, n, size}      call *%reg — an indirect target (closure code)
//   {k:K.diff, a, b}        a-b as imm32 (rodata lengths)
// An encoder writes the instruction's bytes FORWARD into a caller-owned
// scratch through a cursor (see "the byte sink" below) and returns
// {at: the cursor past the instruction, fix: [...], err: str}; the
// instruction is scratch[0:at].
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

// ── the byte sink ───────────────────────────────────────────────────────
// An instruction is written byte by byte into a scratch the caller owns,
// through a cursor `at`, and read back as scratch[0:at]. It used to be
// assembled by concatenating little arrays instead — `concat(prefix, tail)`,
// `concat(prefix, le32(v))`, `with_rex(r, b)` prepending one more — which
// allocated two or three `[byte]`s per step, for a three-byte instruction,
// and that is where the assembler spent its memory: 368 MB of an 838 MB
// compile of ycc.y, in `concat` alone 512,082 allocations and 1,057,134
// single-byte pushes.
//
// x86 orders a form opcode, ModRM, SIB, displacement, immediate — which is
// exactly the order the encoders below write them — so `at` only ever moves
// forward and no encoder needs to backfill. That is what makes the shape
// possible: the old model prepended a REX prefix after the fact, which is
// why with_rex existed and why enc_mem_result had to add 1 to a fixup
// offset to account for a prefix it had not written yet.
def scratch() -> [byte] {
    // 16 slots; the longest form below is 12 bytes (`mov $imm32, mem(%rip)`:
    // REX, opcode, ModRM, SIB, disp32, imm32). Writing past the end traps
    // ("index out of bounds"), so an encoder that overruns is loud.
    // NOTE: annotated `[byte]`, not a bare hole (elf.y push_bytes note): a
    // hole would take its element type from the call site.
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
    let n = put2(buf, at, byte_of(v, 0), byte_of(v, 1));
    put2(buf, n, byte_of(v, 2), byte_of(v, 3))
};

def put_le64(buf: [byte], at: long, v: long) -> long {
    let n = put_le32(buf, at, v);
    put_le32(buf, n, div_floor(v, 4294967296))
};

// The REX prefix, or nothing: -1 means the form needs no prefix, and the
// cursor does not move.
def put_rex(buf: [byte], at: long, r: long) -> long {
    if (r < 0) { at } else { put(buf, at, r) }
};

// Encode a memory operand's tail (ModRM + optional SIB + displacement).
// Returns {modrm, sib, ne, disp, rip_lbl}: the caller writes the opcode and
// the ModRM, then mem_tail_put writes `sib` (or -1 for none) and the `ne`
// displacement bytes at `disp`, then any immediate — x86's own order.
// `rip_lbl` non-empty says a label-relative disp32 follows the tail, which
// enc_mem_result / enc_mem_imm_result write as a placeholder with a fixup.
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

// Fixup record for label-relative fields, resolved in pass 2:
// {off, kind, lbl, lbl2} (off relative to instruction start).
// kind: "rel32" (call/jmp/jcc), "rip32", "imm32diff".
type Fixup = { off: long, kind: str, lbl: str, lbl2: str };
def fixup(at: long, kind: str, lbl: str, lbl2: str) -> Fixup {
    { off: at, kind: kind, lbl: lbl, lbl2: lbl2 }
};

// ── instruction encoders ───────────────────────────────────────────────
// Each writes its bytes into `buf` from `at` and returns {at, fix, err, br},
// with every fixup offset relative to the instruction's first byte (which is
// where the caller started), and `br` the branch this instruction is (0 for
// jmp, the long form's condition byte for a jcc, -1 for everything else) so
// the assembler's relaxation pass can re-encode one without re-parsing its
// line. Only forms our backend emits exist.
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
    if (o.k != K.reg) {
        enc_err(at, "push needs r64")
    } else if (op_size(o) != 64) {
        enc_err(at, "push needs r64")
    } else {
        let n = put_rex(buf, at, rex(false, -1, -1, o.n));
        enc_ok(put(buf, n, 80 + (o.n % 8)), [])
    }
};

def enc_pop(buf: [byte], at: long, o: Operand) -> Encoded {
    if (o.k != K.reg) {
        enc_err(at, "pop needs r64")
    } else if (op_size(o) != 64) {
        enc_err(at, "pop needs r64")
    } else {
        let n = put_rex(buf, at, rex(false, -1, -1, o.n));
        enc_ok(put(buf, n, 88 + (o.n % 8)), [])
    }
};

def enc_mov(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && src.k == K.reg) {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            let n = put_rex(buf, at, rex(true, src.n, -1, dst.n));
            enc_ok(put2(buf, n, 137, modrm(3, src.n, dst.n)), [])
        } else {
            enc_err(at, "mov reg,reg size mix")
        }
    } else if (dst.k == K.reg && src.k == K.imm) {
        if (op_size(dst) == 64) {
            if (src.v >= -2147483648 && src.v <= 2147483647) {
                let n = put_rex(buf, at, rex(true, -1, -1, dst.n));
                let m = put2(buf, n, 199, modrm(3, 0, dst.n));
                enc_ok(put_le32(buf, m, src.v), [])
            } else {
                let n = put_rex(buf, at, rex(true, -1, -1, dst.n));
                let m = put(buf, n, 184 + (dst.n % 8));
                enc_ok(put_le64(buf, m, src.v), [])
            }
        } else if (op_size(dst) == 32) {
            let n = put_rex(buf, at, rex(false, -1, -1, dst.n));
            let m = put2(buf, n, 199, modrm(3, 0, dst.n));
            enc_ok(put_le32(buf, m, src.v), [])
        } else {
            enc_err(at, "mov imm size")
        }
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.diff) {
        let r = rex(true, -1, -1, dst.n);
        let n = put_rex(buf, at, r);
        let m = put2(buf, n, 199, modrm(3, 0, dst.n));
        // the four bytes are placeholders; pass 2 writes src.a - src.b
        let q = put_le32(buf, m, 0);
        let off = 3;
        if (r < 0) { off = 2; };
        enc_ok(q, [fixup(at + off, "imm32diff", src.a, src.b)])
    } else if (dst.k == K.reg && src.k == K.fs && op_size(dst) == 64) {
        // mov %fs:disp32, r64: the fs prefix, REX.W, 8B, a SIB with no
        // base and no index (an absolute disp32)
        let n = put(buf, at, 100);
        let m = put(buf, n, rex(true, dst.n, -1, -1));
        let q = put2(buf, m, 139, modrm(0, dst.n, 4));
        let p = put(buf, q, 37);
        enc_ok(put_le32(buf, p, src.disp), [])
    } else if (dst.k == K.reg && src.k == K.mem) {
        if (op_size(dst) == 64) {
            let t = mem_tail(src, dst.n);
            let n = put_rex(buf, at, rex_rm(true, dst.n, src));
            let m = put2(buf, n, 139, t.modrm);
            enc_mem_result(buf, mem_tail_put(buf, m, t), t)
        } else {
            enc_err(at, "mov r,mem size")
        }
    } else if (dst.k == K.mem && src.k == K.imm) {
        // mov $imm32, mem (length/cap stores)
        let t = mem_tail(dst, 0);
        let n = put_rex(buf, at, rex_rm(true, 0, dst));
        let m = put2(buf, n, 199, t.modrm);
        enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, src.v, true)
    } else if (dst.k == K.mem && src.k == K.reg) {
        if (op_size(src) == 64) {
            let t = mem_tail(dst, src.n);
            let n = put_rex(buf, at, rex_rm(true, src.n, dst));
            let m = put2(buf, n, 137, t.modrm);
            enc_mem_result(buf, mem_tail_put(buf, m, t), t)
        } else if (op_size(src) == 8) {
            let t = mem_tail(dst, src.n);
            let n = put_rex(buf, at, rex_rm(false, src.n, dst));
            let m = put2(buf, n, 136, t.modrm);
            enc_mem_result(buf, mem_tail_put(buf, m, t), t)
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
        let n = put_rex(buf, at, rex_rm(true, reg.n, mem));
        let m = put2(buf, n, 135, t.modrm);
        enc_mem_result(buf, mem_tail_put(buf, m, t), t)
    }
};

// The tail's label-relative disp32 for a form with no immediate after it:
// four placeholder bytes the linker fills in, with the fixup pointing at
// them — the cursor, which is where they start. (The old model appended the
// placeholders to an array and added 1 to the offset when a REX prefix was
// about to be prepended; writing forward, the prefix is already written.)
def enc_mem_result(buf: [byte], at: long, t: MemTail) -> Encoded {
    if (t.modrm < 0) {
        enc_err(at, "bad memory form")
    } else if (t.rip_lbl == "") {
        enc_ok(at, [])
    } else {
        enc_ok(put_le32(buf, at, 0), [fixup(at, "rip32", t.rip_lbl, "")])
    }
};

// Like enc_mem_result, but for the forms whose immediate comes AFTER the
// memory operand (C7 /0 id, C6 /0 ib, 83 /ext ib, 81 /ext id). x86 orders a
// form ModRM, SIB, displacement, immediate, while enc_mem_result's
// placeholder would come after the immediate -- so the forms with an
// immediate need this order. It matters for `mov $imm32, sym(%rip)`: with the
// placeholder after the immediate the instruction silently addresses the
// wrong 4 bytes.
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
        let n = put_rex(buf, at, rex_rm(false, 0, dst));
        let m = put2(buf, n, 198, t.modrm);
        enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, src.v, false)
    }
};

def enc_movzbq(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 8) {
        let n = put_rex(buf, at, rex(true, dst.n, -1, src.n));
        enc_ok(put3(buf, n, 15, 182, modrm(3, dst.n, src.n)), [])
    } else if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        // movzbq mem8 -> r64 (single-byte loads for string data)
        let t = mem_tail(src, dst.n);
        let n = put_rex(buf, at, rex_rm(true, dst.n, src));
        let m = put3(buf, n, 15, 182, t.modrm);
        enc_mem_result(buf, mem_tail_put(buf, m, t), t)
    } else {
        enc_err(at, "movzbq form")
    }
};

def enc_lea(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.mem) {
        let t = mem_tail(src, dst.n);
        let n = put_rex(buf, at, rex_rm(true, dst.n, src));
        let m = put2(buf, n, 141, t.modrm);
        enc_mem_result(buf, mem_tail_put(buf, m, t), t)
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
        let n = put_rex(buf, at, rex(true, src.n, -1, dst.n));
        enc_ok(put2(buf, n, base, modrm(3, src.n, dst.n)), [])
    } else {
        enc_err(at, "arith reg form")
    }
};

def enc_xor32(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 32 && src.k == K.reg && op_size(src) == 32) {
        let n = put_rex(buf, at, rex(false, src.n, -1, dst.n));
        enc_ok(put2(buf, n, 49, modrm(3, src.n, dst.n)), [])
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
    // (split from enc_alu_imm: the shape gate above narrows; this body sees a
    // memory destination, and no size -- a memory operand carries none, so this
    // is the 64-bit form, which is what a Y long is. GNU as guesses 32-bit for
    // a sizeless memory operand with no register operand, and that would zero
    // the upper half of every long.)
    let ext = alu_ext(op);
    if (fits8(v)) {
        let t = mem_tail(dst, ext);
        let n = put_rex(buf, at, rex_rm(true, ext, dst));
        let m = put2(buf, n, 131, t.modrm);
        enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, v, false)
    } else if (v < -2147483648 || v > 2147483647) {
        // the same door the register form has (see enc_alu_imm_body)
        enc_err(at, "an immediate does not fit in 32 bits")
    } else {
        let t = mem_tail(dst, ext);
        let n = put_rex(buf, at, rex_rm(true, ext, dst));
        let m = put2(buf, n, 129, t.modrm);
        enc_mem_imm_result(buf, mem_tail_put(buf, m, t), t, v, true)
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
    let wide = op_size(dst) == 64;
    let r = rex(wide, -1, -1, dst.n);
    if (fits8(v)) {
        let n = put_rex(buf, at, r);
        let m = put2(buf, n, 131, modrm(3, ext, dst.n));
        enc_ok(put(buf, m, u8(v)), [])
    } else if (v < -2147483648 || v > 2147483647) {
        // 81 /n id takes a sign-extended imm32 and nothing else, and put_le32
        // would quietly keep the low four bytes: `cmp $4294967366, %rcx` (a
        // fixed array of 4 billion elements) would encode as `cmp $10` and
        // the bounds check would pass for every index under ten. No emitter
        // path reaches it -- the checker caps a fixed array's size at int32
        // ("an integer literal from 0 to 2147483647 in a type") and every
        // other immediate here is a frame offset or a small constant -- but
        // an encoder that would quietly encode a different instruction is
        // worth a door, and this is that door.
        enc_err(at, "an immediate does not fit in 32 bits")
    } else {
        let n = put_rex(buf, at, r);
        let m = put2(buf, n, 129, modrm(3, ext, dst.n));
        enc_ok(put_le32(buf, m, v), [])
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
            let n = put_rex(buf, at, rex(true, -1, -1, dst.n));
            enc_ok(put2(buf, n, 211, modrm(3, ext, dst.n)), [])
        } else {
            enc_err(at, mn + " count register is %cl")
        }
    } else if (cnt.k == K.imm) {
        if (cnt.v < 0 || cnt.v > 63) {
            enc_err(at, mn + " count range")
        } else {
            let n = put_rex(buf, at, rex(true, -1, -1, dst.n));
            let m = put2(buf, n, 193, modrm(3, ext, dst.n));
            enc_ok(put(buf, m, u8(cnt.v)), [])
        }
    } else {
        enc_err(at, mn + " count")
    }
};

// ── SSE scalar-double encodings ────────────────────────────────────────
// Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
// comparison move them into %xmmN, so the rest of the backend (slots,
// pushes, calls) is unchanged.

def enc_sse_arith(buf: [byte], at: long, mn: str, dst: Operand, src: Operand) -> Encoded {
    // F2 0F <op> /r  — addsd 58, subsd 5C, mulsd 59, divsd 5E
    if (dst.k != K.reg) {
        enc_err(at, "sse dst")
    } else if (src.k != K.reg) {
        enc_err(at, "sse src")
    } else {
        let op = 88;
        if (mn == "subsd") { op = 92; }
        if (mn == "mulsd") { op = 89; }
        if (mn == "divsd") { op = 94; }
        let n = put(buf, at, 242);
        let m = put_rex(buf, n, rex(false, dst.n, -1, src.n));
        enc_ok(put3(buf, m, 15, op, modrm(3, dst.n, src.n)), [])
    }
};

def enc_ucomisd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // 66 0F 2E /r
    if (dst.k != K.reg) {
        enc_err(at, "ucomisd dst")
    } else if (src.k != K.reg) {
        enc_err(at, "ucomisd src")
    } else {
        let n = put(buf, at, 102);
        let m = put_rex(buf, n, rex(false, dst.n, -1, src.n));
        enc_ok(put3(buf, m, 15, 46, modrm(3, dst.n, src.n)), [])
    }
};

def enc_cvtsi2sd(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // F2 REX.W 0F 2A /r  — cvtsi2sd %gpr, %xmm
    if (dst.k != K.reg) {
        enc_err(at, "cvtsi2sd dst")
    } else if (src.k != K.reg) {
        enc_err(at, "cvtsi2sd src")
    } else {
        let n = put(buf, at, 242);
        let m = put(buf, n, rex(true, dst.n, -1, src.n));
        enc_ok(put3(buf, m, 15, 42, modrm(3, dst.n, src.n)), [])
    }
};

def enc_cvttsd2si(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating)
    if (dst.k != K.reg) {
        enc_err(at, "cvttsd2si dst")
    } else if (src.k != K.reg) {
        enc_err(at, "cvttsd2si src")
    } else {
        let n = put(buf, at, 242);
        let m = put(buf, n, rex(true, dst.n, -1, src.n));
        enc_ok(put3(buf, m, 15, 44, modrm(3, dst.n, src.n)), [])
    }
};

def enc_movq(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
    // 66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr)
    if (dst.k != K.reg) {
        enc_err(at, "movq dst")
    } else if (src.k != K.reg) {
        enc_err(at, "movq src")
    } else if (op_size(dst) == 128) {
        // into an xmm: the xmm is the reg field, the gpr the rm field
        let n = put(buf, at, 102);
        let m = put(buf, n, rex(true, dst.n, -1, src.n));
        enc_ok(put3(buf, m, 15, 110, modrm(3, dst.n, src.n)), [])
    } else if (op_size(src) != 128) {
        // Neither side is an xmm, so this is not a float move at all. Taking
        // it as one would quietly read an SSE register and write a GPR (or the
        // other way round) where the source said a register move -- a silent
        // miscompile, and this assembler's one rule is to be loud instead.
        enc_err(at, "movq needs an xmm register")
    } else {
        // out of an xmm: 66 REX.W 0F 7E /r is reg=xmm, rm=r/m64
        let n = put(buf, at, 102);
        let m = put(buf, n, rex(true, src.n, -1, dst.n));
        enc_ok(put3(buf, m, 15, 126, modrm(3, src.n, dst.n)), [])
    }
};

def enc_imul(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    if (dst.k == K.reg && op_size(dst) == 64 && src.k == K.reg && op_size(src) == 64) {
        let n = put_rex(buf, at, rex(true, dst.n, -1, src.n));
        enc_ok(put3(buf, n, 15, 175, modrm(3, dst.n, src.n)), [])
    } else {
        enc_err(at, "imul form")
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
        let n = put_rex(buf, at, rex(true, -1, -1, o.n));
        enc_ok(put2(buf, n, opc, modrm(3, ext, o.n)), [])
    }
};

def enc_unary_mem(buf: [byte], at: long, op: str, o: Operand) -> Encoded {
    // (split from enc_unary: the shape gate above narrows; this body sees a
    // memory operand, hence a ModRM that is not mod=11.) inc/dec/not have
    // memory forms -- FF /0, FF /1, F7 /2 -- and are 64-bit here for the same
    // reason the ALU form is. idiv/div/imul/neg do not (their encoding is
    // F7 with mod=11 only), so they stay an error.
    let ext = 0;
    let opc = 255;
    if (op == "dec") { ext = 1; }
    else if (op == "not") { ext = 2; opc = 247; };
    if (op == "inc" || op == "dec" || op == "not") {
        let t = mem_tail(o, ext);
        let n = put_rex(buf, at, rex_rm(true, ext, o));
        let m = put2(buf, n, opc, t.modrm);
        enc_mem_result(buf, mem_tail_put(buf, m, t), t)
    } else {
        enc_err(at, "unary form")
    }
};

// A branch is encoded in the short (rel8) or long (rel32) form on request:
// `EB rel8` / `E9 rel32`, and `70+cc rel8` / `0F 80+cc rel32` for a
// conditional. Which form an instruction gets is not the encoder's to decide —
// an instruction's length has to be known before the addresses are, and a
// branch's target is usually not where it is yet — so the assembler asks for
// short first and grows the ones that turn out to be out of range (asm.y's
// asm_relax). `code` is the long form's condition byte (0x84 for je, 0x85 for
// jne, ...), which setcc shares.
def enc_jmp(buf: [byte], at: long, o: Operand, lng: bool) -> Encoded {
    if (o.k != K.lbl) {
        enc_err(at, "jmp target")
    } else if (lng) {
        let n = put(buf, at, 233);
        let m = put_le32(buf, n, 0);
        enc_br(m, [fixup(at + 1, "rel32", o.name, "")], 0)
    } else {
        let n = put(buf, at, 235);
        enc_br(put(buf, n, 0), [fixup(at + 1, "rel8", o.name, "")], 0)
    }
};

def enc_call(buf: [byte], at: long, o: Operand) -> Encoded {
    if (o.k == K.ind) {
        // call *%reg — FF /2, used for closure code pointers.
        let n = put_rex(buf, at, rex(false, 0, -1, o.n));
        enc_ok(put2(buf, n, 255, modrm(3, 2, o.n)), [])
    } else if (o.k != K.lbl) {
        enc_err(at, "call target")
    } else {
        let n = put(buf, at, 232);
        let m = put_le32(buf, n, 0);
        enc_ok(m, [fixup(at + 1, "rel32", o.name, "")])
    }
};

def enc_jcc(buf: [byte], at: long, code: long, o: Operand, lng: bool) -> Encoded {
    if (o.k != K.lbl) {
        enc_err(at, "jcc target")
    } else if (lng) {
        let n = put2(buf, at, 15, code);
        let m = put_le32(buf, n, 0);
        enc_br(m, [fixup(at + 2, "rel32", o.name, "")], code)
    } else {
        // the short form's opcode is the long form's 16 bytes lower
        let n = put(buf, at, code - 16);
        enc_br(put(buf, n, 0), [fixup(at + 1, "rel8", o.name, "")], code)
    }
};

def enc_setcc(buf: [byte], at: long, code: long, o: Operand) -> Encoded {
    if (o.k != K.reg || op_size(o) != 8) {
        enc_err(at, "setcc form")
    } else {
        let n = put_rex(buf, at, rex(false, -1, -1, o.n));
        enc_ok(put3(buf, n, 15, code, modrm(3, 0, o.n)), [])
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
        let n = put_rex(buf, at, rex_rm(false, 7, m));
        let q = put2(buf, n, 128, t.modrm);
        enc_mem_imm_result(buf, mem_tail_put(buf, q, t), t, v, false)
    }
};

def enc_movb_reg(buf: [byte], at: long, dst: Operand, src: Operand) -> Encoded {
    // movb %r8 -> mem8 (single-byte stores for string data)
    if (dst.k == K.mem && src.k == K.reg && op_size(src) == 8) {
        let t = mem_tail(dst, src.n);
        let n = put_rex(buf, at, rex_rm(false, src.n, dst));
        let m = put2(buf, n, 136, t.modrm);
        enc_mem_result(buf, mem_tail_put(buf, m, t), t)
    } else {
        enc_err(at, "movb reg form")
    }
};

// ── mnemonic dispatch ──────────────────────────────────────────────────
// A ladder of string comparisons, and it stays one: the plan wanted a
// mnemonic id ("dispatch on a mnemonic id rather than a string"), and the id
// version is measurably SLOWER on this tree. Encoding ycc.y walks this ladder
// 6.69 arms deep per instruction; a whole-string comparison costs 29
// instructions (measured), and a *character* read — what a hash walk needs —
// costs 35 (measured), so hashing a 3-character name costs about what six
// ladder arms do, and the id table came out +0.62% on every benchmark. The
// whole dispatch is 194 instructions per emitted instruction, 0.85% of a
// compile; an ordering that only reorders it by this workload's frequencies
// would buy 0.30% and make the ladder's order a function of the corpus. The
// id is worth having when the emitter stops producing text (Part 4 stage 2);
// until then this ladder is the cheapest dispatch the primitives allow.

def need1(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 1) { mn + " takes 1 operand" } else { "" }
};

def need2(mn: str, ops: [Operand]) -> str {
    if (len(ops) != 2) { mn + " takes 2 operands" } else { "" }
};

// `lng` is the branch form: false asks for the short (rel8) encoding, true for
// rel32. Only jmp and the jcc family read it; everything else ignores it. See
// enc_jmp for why it is a parameter and not the encoder's own decision.
//
// This is the TEXT path: the mnemonic arrives as a string and the arm is a
// string compare. The emitter's own instructions come in as IR items and take
// enc_form below instead, which dispatches on the form id.
def enc_insn(buf: [byte], at: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    if (mn == "push") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_push(buf, at, ops[0]) }
    } else if (mn == "pop") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_pop(buf, at, ops[0]) }
    } else if (mn == "mov") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_mov(buf, at, ops[1], ops[0]) }
    } else if (mn == "movb") {
        let e = need2(mn, ops);
        if (e != "") {
            enc_err(at, e)
        } else if (ops[0].k == K.imm) {
            enc_movb(buf, at, ops[1], ops[0])
        } else {
            enc_movb_reg(buf, at, ops[1], ops[0])
        }
    } else if (mn == "movzbq") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_movzbq(buf, at, ops[1], ops[0]) }
    } else if (mn == "lea") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_lea(buf, at, ops[1], ops[0]) }
    } else if (mn == "xchg") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_xchg(buf, at, ops[0], ops[1]) }
    } else if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or" || mn == "test") {
        let e = need2(mn, ops);
        if (e != "") {
            enc_err(at, e)
        } else {
            let dst = ops[1];
            let src = ops[0];
            if (src.k == K.imm) {
                if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or") {
                    enc_alu_imm(buf, at, mn, dst, src.v)
                } else {
                    enc_err(at, mn + " imm form")
                }
            } else if (dst.k == K.reg && src.k == K.reg && mn == "xor" && op_size(dst) == 32 && op_size(src) == 32) {
                enc_xor32(buf, at, dst, src)
            } else {
                enc_arith(buf, at, mn, dst, src)
            }
        }
    } else if (mn == "shl" || mn == "shr" || mn == "sar") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_shift(buf, at, mn, ops[1], ops[0]) }
    } else if (mn == "addsd" || mn == "subsd" || mn == "mulsd" || mn == "divsd") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_sse_arith(buf, at, mn, ops[1], ops[0]) }
    } else if (mn == "ucomisd") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_ucomisd(buf, at, ops[1], ops[0]) }
    } else if (mn == "cvtsi2sd") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_cvtsi2sd(buf, at, ops[1], ops[0]) }
    } else if (mn == "cvttsd2si") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_cvttsd2si(buf, at, ops[1], ops[0]) }
    } else if (mn == "movq") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_movq(buf, at, ops[1], ops[0]) }
    } else if (mn == "imul") {
        let e = need2(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_imul(buf, at, ops[1], ops[0]) }
    } else if (mn == "neg" || mn == "not" || mn == "idiv" || mn == "div" || mn == "dec" || mn == "inc") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_unary(buf, at, mn, ops[0]) }
    } else if (mn == "jmp") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jmp(buf, at, ops[0], lng) }
    } else if (mn == "call") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_call(buf, at, ops[0]) }
    } else if (mn == "jz" || mn == "je") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 132, ops[0], lng) }
    } else if (mn == "jnz" || mn == "jne") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 133, ops[0], lng) }
    } else if (mn == "js") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 136, ops[0], lng) }
    } else if (mn == "jns") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 137, ops[0], lng) }
    } else if (mn == "jge") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 141, ops[0], lng) }
    } else if (mn == "jl") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 140, ops[0], lng) }
    } else if (mn == "jle") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 142, ops[0], lng) }
    } else if (mn == "jg") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 143, ops[0], lng) }
    } else if (mn == "jb") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_jcc(buf, at, 130, ops[0], lng) }
    } else if (mn == "setl") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 156, ops[0]) }
    } else if (mn == "setg") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 159, ops[0]) }
    } else if (mn == "setle") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 158, ops[0]) }
    } else if (mn == "setge") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 157, ops[0]) }
    } else if (mn == "sete") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 148, ops[0]) }
    } else if (mn == "setne") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 149, ops[0]) }
    } else if (mn == "seta") {
        // unsigned >: the correct condition after ucomisd (floats)
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 151, ops[0]) }
    } else if (mn == "setae") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 147, ops[0]) }
    } else if (mn == "setb") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 146, ops[0]) }
    } else if (mn == "setbe") {
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 150, ops[0]) }
    } else if (mn == "setp") {
        // parity set: after ucomisd, unordered
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 154, ops[0]) }
    } else if (mn == "setnp") {
        // parity clear: after ucomisd, ordered
        let e = need1(mn, ops);
        if (e != "") { enc_err(at, e) } else { enc_setcc(buf, at, 155, ops[0]) }
    } else if (mn == "cmpb") {
        let e = need2(mn, ops);
        if (e != "") {
            enc_err(at, e)
        } else if (ops[0].k != K.imm) {
            enc_err(at, "cmpb needs imm")
        } else {
            enc_cmpb(buf, at, ops[0].v, ops[1])
        }
    } else if (mn == "cqo") {
        enc_ok(put2(buf, at, 72, 153), [])
    } else if (mn == "syscall") {
        enc_ok(put2(buf, at, 15, 5), [])
    } else if (mn == "ret") {
        enc_ok(put(buf, at, 195), [])
    } else {
        enc_err(at, "unknown mnemonic '" + mn + "'")
    }
};


// The same encoders, dispatched on the IR's form id (Part 4 stage 2c): an item
// names a form, not a mnemonic, so the arm is an integer compare rather than a
// string one. Every arm is what enc_insn does for that mnemonic and those
// operand kinds -- the form says statically what enc_insn has to test -- and
// the ladder is generated from the form table and those rules (see the audit
// note in the commit), so the two cannot drift apart by hand. `mn` is the
// form's mnemonic: the ALU family, the shifts, the SSE arithmetic and the
// unary ops key on it. `ops` are the item's operands in enc_insn's order (the
// source first, as the assembly text spells them).
def enc_form(buf: [byte], at: long, f: long, mn: str, ops: [Operand], lng: bool) -> Encoded {
    if (f == 0) { enc_push(buf, at, ops[0]) }  // push O_REG
    else if (f == 1) { enc_pop(buf, at, ops[0]) }  // pop O_REG
    else if (f == 2) { enc_call(buf, at, ops[0]) }  // call O_LBL
    else if (f == 3) { enc_call(buf, at, ops[0]) }  // call O_IND
    else if (f == 4) { enc_jmp(buf, at, ops[0], lng) }  // jmp O_LBL
    else if (f == 5) { enc_ok(put(buf, at, 195), []) }  // ret 
    else if (f == 6) { enc_jcc(buf, at, 132, ops[0], lng) }  // je O_LBL
    else if (f == 7) { enc_jcc(buf, at, 133, ops[0], lng) }  // jne O_LBL
    else if (f == 8) { enc_jcc(buf, at, 132, ops[0], lng) }  // jz O_LBL
    else if (f == 9) { enc_jcc(buf, at, 133, ops[0], lng) }  // jnz O_LBL
    else if (f == 10) { enc_jcc(buf, at, 136, ops[0], lng) }  // js O_LBL
    else if (f == 11) { enc_jcc(buf, at, 141, ops[0], lng) }  // jge O_LBL
    else if (f == 12) { enc_jcc(buf, at, 142, ops[0], lng) }  // jle O_LBL
    else if (f == 13) { enc_jcc(buf, at, 140, ops[0], lng) }  // jl O_LBL
    else if (f == 14) { enc_jcc(buf, at, 143, ops[0], lng) }  // jg O_LBL
    else if (f == 15) { enc_jcc(buf, at, 130, ops[0], lng) }  // jb O_LBL
    else if (f == 16) { enc_jcc(buf, at, 137, ops[0], lng) }  // jns O_LBL
    else if (f == 17) { enc_setcc(buf, at, 148, ops[0]) }  // sete O_REG
    else if (f == 18) { enc_setcc(buf, at, 149, ops[0]) }  // setne O_REG
    else if (f == 19) { enc_setcc(buf, at, 156, ops[0]) }  // setl O_REG
    else if (f == 20) { enc_setcc(buf, at, 159, ops[0]) }  // setg O_REG
    else if (f == 21) { enc_setcc(buf, at, 157, ops[0]) }  // setge O_REG
    else if (f == 22) { enc_setcc(buf, at, 158, ops[0]) }  // setle O_REG
    else if (f == 23) { enc_setcc(buf, at, 151, ops[0]) }  // seta O_REG
    else if (f == 24) { enc_setcc(buf, at, 147, ops[0]) }  // setae O_REG
    else if (f == 25) { enc_setcc(buf, at, 155, ops[0]) }  // setnp O_REG
    else if (f == 26) { enc_setcc(buf, at, 154, ops[0]) }  // setp O_REG
    else if (f == 27) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_REG O_REG
    else if (f == 28) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_REG O_MEM
    else if (f == 29) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_REG O_MEM
    else if (f == 30) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_REG O_MEM0
    else if (f == 31) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_REG O_MEM
    else if (f == 32) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_MEM O_REG
    else if (f == 33) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_MEM O_REG
    else if (f == 34) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_MEM0 O_REG
    else if (f == 35) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_MEM O_REG
    else if (f == 36) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_IMM O_REG
    else if (f == 37) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_IMM O_MEM
    else if (f == 38) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_IMM O_MEM0
    else if (f == 39) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_IMM O_MEM
    else if (f == 40) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_DIFF O_REG
    else if (f == 41) { enc_movb_reg(buf, at, ops[1], ops[0]) }  // movb O_REG O_MEM
    else if (f == 42) { enc_movb_reg(buf, at, ops[1], ops[0]) }  // movb O_REG O_MEM0
    else if (f == 43) { enc_movb_reg(buf, at, ops[1], ops[0]) }  // movb O_REG O_MEM
    else if (f == 44) { enc_movb(buf, at, ops[1], ops[0]) }  // movb O_IMM O_MEM
    else if (f == 45) { enc_movb(buf, at, ops[1], ops[0]) }  // movb O_IMM O_MEM0
    else if (f == 46) { enc_movb(buf, at, ops[1], ops[0]) }  // movb O_IMM O_MEM
    else if (f == 47) { enc_movq(buf, at, ops[1], ops[0]) }  // movq O_REG O_REG
    else if (f == 48) { enc_movzbq(buf, at, ops[1], ops[0]) }  // movzbq O_REG O_REG
    else if (f == 49) { enc_movzbq(buf, at, ops[1], ops[0]) }  // movzbq O_MEM O_REG
    else if (f == 50) { enc_movzbq(buf, at, ops[1], ops[0]) }  // movzbq O_MEM0 O_REG
    else if (f == 51) { enc_movzbq(buf, at, ops[1], ops[0]) }  // movzbq O_MEM O_REG
    else if (f == 52) { enc_lea(buf, at, ops[1], ops[0]) }  // lea O_MEM O_REG
    else if (f == 53) { enc_lea(buf, at, ops[1], ops[0]) }  // lea O_MEM O_REG
    else if (f == 54) { enc_lea(buf, at, ops[1], ops[0]) }  // lea O_MEM O_REG
    else if (f == 55) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // add O_IMM O_REG
    else if (f == 56) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // add O_REG O_REG
    else if (f == 57) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // add O_IMM O_MEM
    else if (f == 58) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // sub O_IMM O_REG
    else if (f == 59) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // sub O_REG O_REG
    else if (f == 60) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // sub O_IMM O_MEM
    else if (f == 61) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // xor O_IMM O_REG
    else if (f == 62) {  // xor O_REG O_REG
        if (op_size(ops[1]) == 32 && op_size(ops[0]) == 32) {
            enc_xor32(buf, at, ops[1], ops[0])
        } else {
            enc_arith(buf, at, mn, ops[1], ops[0])
        }
    }
    else if (f == 63) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // xor O_IMM O_MEM
    else if (f == 64) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // and O_IMM O_REG
    else if (f == 65) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // and O_REG O_REG
    else if (f == 66) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // and O_IMM O_MEM
    else if (f == 67) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // or O_REG O_REG
    else if (f == 68) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // or O_IMM O_MEM
    else if (f == 69) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // shl O_IMM O_REG
    else if (f == 70) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // shl O_REG O_REG
    else if (f == 71) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // sar O_IMM O_REG
    else if (f == 72) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // sar O_REG O_REG
    else if (f == 73) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // shr O_IMM O_REG
    else if (f == 74) { enc_shift(buf, at, mn, ops[1], ops[0]) }  // shr O_REG O_REG
    else if (f == 75) { enc_alu_imm(buf, at, mn, ops[1], ops[0].v) }  // cmp O_IMM O_REG
    else if (f == 76) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // cmp O_REG O_REG
    else if (f == 77) { enc_arith(buf, at, mn, ops[1], ops[0]) }  // test O_REG O_REG
    else if (f == 78) { enc_imul(buf, at, ops[1], ops[0]) }  // imul O_REG O_REG
    else if (f == 79) { enc_unary(buf, at, mn, ops[0]) }  // idiv O_REG
    else if (f == 80) { enc_unary(buf, at, mn, ops[0]) }  // div O_REG
    else if (f == 81) { enc_unary(buf, at, mn, ops[0]) }  // neg O_REG
    else if (f == 82) { enc_unary(buf, at, mn, ops[0]) }  // not O_REG
    else if (f == 83) { enc_unary(buf, at, mn, ops[0]) }  // inc O_REG
    else if (f == 84) { enc_unary(buf, at, mn, ops[0]) }  // inc O_MEM
    else if (f == 85) { enc_unary(buf, at, mn, ops[0]) }  // dec O_REG
    else if (f == 86) { enc_unary(buf, at, mn, ops[0]) }  // dec O_MEM
    else if (f == 87) { enc_xchg(buf, at, ops[0], ops[1]) }  // xchg O_REG O_MEM
    else if (f == 88) { enc_ok(put2(buf, at, 15, 5), []) }  // syscall 
    else if (f == 89) { enc_ok(put2(buf, at, 72, 153), []) }  // cqo 
    else if (f == 90) { enc_mov(buf, at, ops[1], ops[0]) }  // mov O_FS O_REG
    else if (f == 91) { enc_cvtsi2sd(buf, at, ops[1], ops[0]) }  // cvtsi2sd O_REG O_REG
    else if (f == 92) { enc_sse_arith(buf, at, mn, ops[1], ops[0]) }  // divsd O_REG O_REG
    else if (f == 93) { enc_sse_arith(buf, at, mn, ops[1], ops[0]) }  // mulsd O_REG O_REG
    else if (f == 94) { enc_sse_arith(buf, at, mn, ops[1], ops[0]) }  // addsd O_REG O_REG
    else if (f == 95) { enc_sse_arith(buf, at, mn, ops[1], ops[0]) }  // subsd O_REG O_REG
    else if (f == 96) { enc_ucomisd(buf, at, ops[1], ops[0]) }  // ucomisd O_REG O_REG
    else { enc_err(at, "unknown form '" + mn + "'") }
};

// The types are exported too: enc_insn and enc_form take [Operand] and return
// Encoded, so a caller that wants to name either needs the name.
export { Operand, Fixup, Encoded, MemTail, r64, reg_num, reg_size, enc_insn,
         enc_form, enc_branch_long, fixup, byte_of, scratch, le16, le32, le64 };
