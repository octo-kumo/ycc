// enc64.y — x86-64 instruction encoding for the native backend's subset.
// Operands use the assembler's parsed forms:
//   {k:"reg", n, size}      n = 0-15, size = 64/32/8
//   {k:"imm", v}            signed long
//   {k:"mem", base, idx, scale, disp, rip, lbl}  rip: bool (lbl valid),
//     base/idx: reg numbers (-1 = none), scale 1/2/4/8, disp long
//   {k:"lbl", name}         code label (jumps/calls)
//   {k:"diff", a, b}        a-b as imm32 (rodata lengths)
// Every encode_* returns a list of byte values (0-255).
// Only the forms our backend emits exist here — anything else is a loud
// error from the assembler, never a silent miscompile.
//
// New files must stay in the portable Y subset (parsed by the C compiler).

def r64(n: long) -> {k: str, n: long, size: long} { { k: "reg", n: n, size: 64 } };
def r32(n: long) -> {k: str, n: long, size: long} { { k: "reg", n: n, size: 32 } };
def r8(n: long) -> {k: str, n: long, size: long} { { k: "reg", n: n, size: 8 } };

// Register number by AT&T name. Supports the registers our backend uses.
def reg_num(name: str) -> long {
    // NOTE: nested ifs, not `||` (see lexer.y isalnum note): the C VM
    // evaluates both sides eagerly AND the checker rejects joint gates.
    if (name == "%rax") { 0 }
    else if (name == "%eax") { 0 }
    else if (name == "%al") { 0 }
    else if (name == "%rcx") { 1 }
    else if (name == "%ecx") { 1 }
    else if (name == "%cl") { 1 }
    else if (name == "%rdx") { 2 }
    else if (name == "%edx") { 2 }
    else if (name == "%dl") { 2 }
    else if (name == "%rbx") { 3 }
    else if (name == "%ebx") { 3 }
    else if (name == "%bl") { 3 }
    else if (name == "%rsp") { 4 }
    else if (name == "%esp") { 4 }
    else if (name == "%rbp") { 5 }
    else if (name == "%ebp") { 5 }
    else if (name == "%rsi") { 6 }
    else if (name == "%esi") { 6 }
    else if (name == "%sil") { 6 }
    else if (name == "%rdi") { 7 }
    else if (name == "%edi") { 7 }
    else if (name == "%dil") { 7 }
    else if (name == "%r8") { 8 }
    else if (name == "%r8d") { 8 }
    else if (name == "%r8b") { 8 }
    else if (name == "%r9") { 9 }
    else if (name == "%r9d") { 9 }
    else if (name == "%r9b") { 9 }
    else if (name == "%r10") { 10 }
    else if (name == "%r10d") { 10 }
    else if (name == "%r10b") { 10 }
    else if (name == "%r11") { 11 }
    else if (name == "%r11d") { 11 }
    else if (name == "%r11b") { 11 }
    else if (name == "%r12") { 12 }
    else if (name == "%r12d") { 12 }
    else if (name == "%r13") { 13 }
    else if (name == "%r13d") { 13 }
    else if (name == "%r14") { 14 }
    else if (name == "%r14d") { 14 }
    else if (name == "%r15") { 15 }
    else if (name == "%r15d") { 15 }
    else if (name == "%xmm0") { 0 }
    else if (name == "%xmm1") { 1 }
    else if (name == "%xmm2") { 2 }
    else if (name == "%xmm3") { 3 }
    else if (name == "%xmm4") { 4 }
    else if (name == "%xmm5") { 5 }
    else { -1 }
};

def reg_size(name: str) -> long {
    let c = substr(name, 1, 1);
    if (c == "x") {
        // %xmmN: SSE register (size 128 marks the class apart from GPRs)
        128
    } else if (c == "r") {
        // %r..: 64-bit, unless ends in d/b
        let last = substr(name, len(name) - 1, 1);
        if (last == "d") { 32 } else if (last == "b") { 8 } else { 64 }
    } else {
        // %e..: 32-bit; %..l / %..h legacy: 8-bit; %r.. handled above
        if (c == "e") { 32 } else { 8 }
    }
};

// Safe size read: non-registers yield 0 (never crash on missing keys —
// Y evaluates both sides of &&/|| eagerly, so `o.k == "reg" && o.size`
// would still read .size on a mem/lbl/imm operand).
def op_size(o) -> long {
    if (o.k == "reg") { o.size } else { 0 }
};
def rex(w: bool, r: long, x: long, b: long) -> long {
    // NOTE: `0;` tails (see parser.y parse_binary note): bare-`if` arms take
    // the body's type (long) and poison the sequence gate.
    let v = 64;
    if (w) { v = v + 8; 0; } else { 0 };
    if (r >= 8) { v = v + 4; 0; } else { 0 };
    if (x >= 8) { v = v + 2; 0; } else { 0 };
    if (b >= 8) { v = v + 1; 0; } else { 0 };
    if (v == 64) { -1 } else { v }
};

def modrm(mod: long, reg: long, rm: long) -> long {
    mod * 64 + (reg % 8) * 8 + rm % 8
};

def sib(scale: long, index: long, base: long) -> long {
    // NOTE: `0;` tails (see rex note above).
    let s = 0;
    if (scale == 2) { s = 1; 0; } else if (scale == 4) { s = 2; 0; } else if (scale == 8) { s = 3; 0; } else { 0 };
    s * 64 + (index % 8) * 8 + base % 8
};

def le16(v: long) -> [long] {
    [byte_at(v, 0), byte_at(v, 1)]
};

def le32(v: long) -> [long] {
    [byte_at(v, 0), byte_at(v, 1), byte_at(v, 2), byte_at(v, 3)]
};

def le64(v: long) -> [long] {
    [byte_at(v, 0), byte_at(v, 1), byte_at(v, 2), byte_at(v, 3),
     byte_at(v, 4), byte_at(v, 5), byte_at(v, 6), byte_at(v, 7)]
};

// Exact byte i (0 = least significant) of a signed long. Y division
// truncates, so floor it manually — correct for negatives (unlike %).
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
    // NOTE: Y division truncates toward zero (C semantics), so floor needs
    // a correction when the remainder is nonzero and the signs differ.
    // No `&&` (see lexer.y isalnum note): nested ifs. No bare `/` either:
    // the Y lexer treats a lone "/" outside strings as a comment opener
    // (or a loud error), so division is spelled `divtrunc` below... no —
    // division IS available as an operator; the lexer note above is about
    // the "/" CHARACTER reaching the dispatch arm, not the operator itself.
    // (This comment previously contained a bare "/" example that broke
    // self-lexing; keep "/" out of comments or quote it.)
    let q = v / d;
    let r = v - q * d;
    if (r != 0) {
        if (v < 0) {
            if (d > 0) { q = q - 1; 0; } else { 0 };
            0
        } else if (d < 0) { q = q - 1; 0; } else { 0 };
        0
    } else { 0 };
    q
};

def byte_at(v: long, i: long) -> long {
    let q = div_floor(v, pow256(i));
    q - div_floor(q, 256) * 256
};

def u8(v: long) -> long {
    byte_at(v, 0)
};

// fits in a signed 8-bit immediate?
def fits8(v: long) -> bool {
    // NOTE: nested ifs, not `&&` (see lexer.y isalnum note): the C VM
    // evaluates both sides eagerly AND the checker rejects `&&` mixing
    // comparison-bool with map-field shapes through the same gate.
    if (v >= -128) {
        if (v <= 127) { true } else { false }
    } else { false }
};

// Encode a memory operand tail (ModRM + optional SIB + displacement).
// Returns {modrm, extra: [bytes], rip_lbl/"", disp32: bool} — the caller
// supplies the reg field and any label fixup.
def mem_tail(m, reg: long) -> {modrm: long, extra: [long], rip_lbl: str, disp32: bool} {
    if (m.rip) {
        { modrm: modrm(0, reg, 5), extra: [], rip_lbl: m.lbl, disp32: true }
    } else if (m.idx < 0) {
        // no index: [base+disp]. Low 101 (rbp/r13) needs at least disp8
        // (mod=00 would mean disp32-only); low 100 (rsp/r12) needs SIB
        // with base=rsp encoding (SIB base field 100 + base in SIB byte).
        if (m.base % 8 == 5) {
            // rbp/r13 need at least disp8 (mod=00 would mean disp32-only)
            if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 5), extra: [u8(m.disp)], rip_lbl: "", disp32: false }
            } else {
                { modrm: modrm(2, reg, 5), extra: le32(m.disp), rip_lbl: "", disp32: false }
            }
        } else if (m.base % 8 == 4) {
            // rsp/r12 as base: SIB byte required (index=none, base=rsp).
            // sib(1, 4, 4) = scale 00, index 100 (none), base 100 (rsp).
            let s = sib(1, 4, 4);
            if (m.disp == 0) {
                { modrm: modrm(0, reg, 4), extra: [s], rip_lbl: "", disp32: false }
            } else if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 4), extra: [s, u8(m.disp)], rip_lbl: "", disp32: false }
            } else {
                { modrm: modrm(2, reg, 4), extra: concat([s], le32(m.disp)), rip_lbl: "", disp32: false }
            }
        } else if (m.disp == 0) {
            { modrm: modrm(0, reg, m.base), extra: [], rip_lbl: "", disp32: false }
        } else if (fits8(m.disp)) {
            { modrm: modrm(1, reg, m.base), extra: [u8(m.disp)], rip_lbl: "", disp32: false }
        } else {
            { modrm: modrm(2, reg, m.base), extra: le32(m.disp), rip_lbl: "", disp32: false }
        }
    } else {
        // SIB: [base + idx*scale + disp]. Low 101 needs explicit disp.
        let s = sib(m.scale, m.idx, m.base);
        if (m.base % 8 == 5) {
            if (fits8(m.disp)) {
                { modrm: modrm(1, reg, 4), extra: [s, u8(m.disp)], rip_lbl: "", disp32: false }
            } else {
                { modrm: modrm(2, reg, 4), extra: concat([s], le32(m.disp)), rip_lbl: "", disp32: false }
            }
        } else if (m.disp == 0) {
            { modrm: modrm(0, reg, 4), extra: [s], rip_lbl: "", disp32: false }
        } else if (fits8(m.disp)) {
            { modrm: modrm(1, reg, 4), extra: [s, u8(m.disp)], rip_lbl: "", disp32: false }
        } else {
            { modrm: modrm(2, reg, 4), extra: concat([s], le32(m.disp)), rip_lbl: "", disp32: false }
        }
    }
};

// REX for r/m operands: W + extensions from reg field and mem SIB/base.
def rex_rm(w: bool, reg: long, m) -> long {
    if (m.rip) {
        rex(w, reg, -1, -1)
    } else if (m.idx < 0) {
        rex(w, reg, -1, m.base)
    } else {
        rex(w, reg, m.idx, m.base)
    }
};

def concat(a: [long], b: [long]) -> [long] {
    let out = [];
    let i = 0;
    while (i < len(a)) {
        out = push(out, a[i]);
        i = i + 1;
    };
    let j = 0;
    while (j < len(b)) {
        out = push(out, b[j]);
        j = j + 1;
    };
    out
};

// Fixup record for label-relative fields, resolved in pass 2:
// {off, kind, lbl, lbl2} (off relative to instruction start).
// kind: "rel32" (call/jmp/jcc), "rip32", "imm32diff".
def fixup(at: long, kind: str, lbl: str, lbl2: str) -> {off: long, kind: str, lbl: str, lbl2: str} {
    { off: at, kind: kind, lbl: lbl, lbl2: lbl2 }
};

// ── instruction encoders ───────────────────────────────────────────────
// Each returns {bytes, fix: [{off, kind, lbl, lbl2}]} with off relative to
// the instruction start. Only forms our backend emits exist.

def with_rex(r: long, bytes: [long]) -> [long] {
    if (r < 0) { bytes } else { concat([r], bytes) }
};

// NOTE: no x.y[i] chains or dot-assign (C-toolchain portability); bind first.

def enc_push(o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (o.k != "reg") {
        { bytes: [], fix: [], err: "push needs r64" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "push needs r64" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b = [80 + (o.n % 8)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_pop(o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (o.k != "reg") {
        { bytes: [], fix: [], err: "pop needs r64" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "pop needs r64" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b = [88 + (o.n % 8)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_mov(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (dst.k == "reg" && src.k == "reg") {
        if (op_size(dst) == 64 && op_size(src) == 64) {
            let r = rex(true, src.n, -1, dst.n);
            let b = [137, modrm(3, src.n, dst.n)];
            { bytes: with_rex(r, b), fix: [], err: "" }
        } else {
            { bytes: [], fix: [], err: "mov reg,reg size mix" }
        }
    } else if (dst.k == "reg" && src.k == "imm") {
        if (op_size(dst) == 64) {
            if (src.v >= -2147483648 && src.v <= 2147483647) {
                let r = rex(true, -1, -1, dst.n);
                let b = concat([199, modrm(3, 0, dst.n)], le32(src.v));
                { bytes: with_rex(r, b), fix: [], err: "" }
            } else {
                let r = rex(true, -1, -1, dst.n);
                let b = concat([184 + (dst.n % 8)], le64(src.v));
                { bytes: with_rex(r, b), fix: [], err: "" }
            }
        } else if (op_size(dst) == 32) {
            let r = rex(false, -1, -1, dst.n);
            let b = concat([199, modrm(3, 0, dst.n)], le32(src.v));
            { bytes: with_rex(r, b), fix: [], err: "" }
        } else {
            { bytes: [], fix: [], err: "mov imm size" }
        }
    } else if (dst.k == "reg" && op_size(dst) == 64 && src.k == "diff") {
        let r = rex(true, -1, -1, dst.n);
        let b = concat([199, modrm(3, 0, dst.n)], [0, 0, 0, 0]);
        let off = 3;
        if (r < 0) { off = 2; 0; } else { 0 };
        { bytes: with_rex(r, b), fix: [fixup(off, "imm32diff", src.a, src.b)], err: "" }
    } else if (dst.k == "reg" && src.k == "mem") {
        if (op_size(dst) == 64) {
            let t = mem_tail(src, dst.n);
            let r = rex_rm(true, dst.n, src);
            let b = concat([139, t.modrm], t.extra);
            enc_mem_result(r, b, t)
        } else {
            { bytes: [], fix: [], err: "mov r,mem size" }
        }
    } else if (dst.k == "mem" && src.k == "imm") {
        // mov $imm32, mem (length/cap stores)
        let t = mem_tail(dst, 0);
        let r = rex_rm(true, 0, dst);
        let b = concat(concat([199, t.modrm], t.extra), le32(src.v));
        enc_mem_result(r, b, t)
    } else if (dst.k == "mem" && src.k == "reg") {
        if (op_size(src) == 64) {
            let t = mem_tail(dst, src.n);
            let r = rex_rm(true, src.n, dst);
            let b = concat([137, t.modrm], t.extra);
            enc_mem_result(r, b, t)
        } else if (op_size(src) == 8) {
            let t = mem_tail(dst, src.n);
            let r = rex_rm(false, src.n, dst);
            let b = concat([136, t.modrm], t.extra);
            enc_mem_result(r, b, t)
        } else {
            { bytes: [], fix: [], err: "mov mem,reg size" }
        }
    } else {
        { bytes: [], fix: [], err: "mov form" }
    }
};
def enc_mem_result(r: long, b: [long], t: {modrm: long, extra: [long], rip_lbl: str, disp32: bool}) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (t.modrm < 0) {
        { bytes: [], fix: [], err: "bad memory form" }
    } else {
        let fx = [];
        let bb = b;
        // NOTE: nested ifs, not `&&` (see lexer.y isalnum note): the C VM
        // evaluates both sides eagerly AND the checker rejects the joint gate.
        // NOTE: `0;` tails (see rex note above).
        if (t.disp32) {
            if (t.rip_lbl != "") {
            // fixup offset counts the REX prefix with_rex is about to add;
            // the disp32 placeholder bytes must exist for the patch to land.
                let off = len(b);
                if (r >= 0) { off = off + 1; 0; } else { 0 };
                fx = push(fx, fixup(off, "rip32", t.rip_lbl, ""));
                bb = concat(b, [0, 0, 0, 0]);
                0
            } else { 0 };
            0
        } else { 0 };
        { bytes: with_rex(r, bb), fix: fx, err: "" }
    }
};

def enc_movb(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // movb $imm8, mem
    // NOTE: nested ifs, not `||`/`&&` (see reg_num note above).
    if (dst.k != "mem") {
        { bytes: [], fix: [], err: "movb form" }
    } else if (src.k != "imm") {
        { bytes: [], fix: [], err: "movb form" }
    } else {
        enc_movb_imm(dst, src)
    }
};

def enc_movb_imm(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // (split: shape gate above narrows; this body sees mem/imm only.)
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (src.v < -128) {
        { bytes: [], fix: [], err: "movb imm range" }
    } else if (src.v > 127) {
        { bytes: [], fix: [], err: "movb imm range" }
    } else {
        let t = mem_tail(dst, 0);
        let r = rex_rm(false, 0, dst);
        let b = concat(concat([198, t.modrm], t.extra), [u8(src.v)]);
        enc_mem_result(r, b, t)
    }
};

def enc_movzbq(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (dst.k == "reg" && op_size(dst) == 64 && src.k == "reg" && op_size(src) == 8) {
        let r = rex(true, dst.n, -1, src.n);
        let b = [15, 182, modrm(3, dst.n, src.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else if (dst.k == "reg" && op_size(dst) == 64 && src.k == "mem") {
        // movzbq mem8 -> r64 (single-byte loads for string data)
        let t = mem_tail(src, dst.n);
        let r = rex_rm(true, dst.n, src);
        let b = concat([15, 182, t.modrm], t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "movzbq form" }
    }
};

def enc_lea(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (dst.k == "reg" && op_size(dst) == 64 && src.k == "mem") {
        let t = mem_tail(src, dst.n);
        let r = rex_rm(true, dst.n, src);
        let b = concat([141, t.modrm], t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "lea form" }
    }
};

def enc_arith(op: str, dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // op: add/sub/xor/and/or/cmp/test; r64,r64 only here
    if (dst.k == "reg" && op_size(dst) == 64 && src.k == "reg" && op_size(src) == 64) {
        let base = 1;
        if (op == "sub") { base = 41; 0; }
        else if (op == "xor") { base = 49; 0; }
        else if (op == "and") { base = 33; 0; }
        else if (op == "or") { base = 9; 0; }
        else if (op == "cmp") { base = 57; 0; }
        else if (op == "test") { base = 133; 0; }
        else { 0 };
        let r = rex(true, src.n, -1, dst.n);
        let b = [base, modrm(3, src.n, dst.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "arith reg form" }
    }
};

def enc_xor32(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (dst.k == "reg" && op_size(dst) == 32 && src.k == "reg" && op_size(src) == 32) {
        let r = rex(false, src.n, -1, dst.n);
        let b = [49, modrm(3, src.n, dst.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "xor32 form" }
    }
};

def enc_alu_imm(op: str, dst, v: long) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // add/sub/cmp/xor/and/or $imm, %r64; cmp $imm, %r32
    // NOTE: nested ifs, not `||`/`&&` (see reg_num note above).
    if (dst.k != "reg") {
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

def enc_alu_imm_go(op: str, dst, v: long) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // (split from enc_alu_imm: the size gate above narrows; this body sees
    // only r64/r32 regs — no merged-shape reads.)
    enc_alu_imm_body(op, dst, v)
};

def enc_alu_imm_body(op: str, dst, v: long) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // NOTE: split from enc_alu_imm (see note above): no size gate here.
    let ext = 0;
    if (op == "sub") { ext = 5; 0; }
    else if (op == "cmp") { ext = 7; 0; }
    else if (op == "xor") { ext = 6; 0; }
    else if (op == "and") { ext = 4; 0; }
    else if (op == "or") { ext = 1; 0; }
    else { 0 };
    let wide = op_size(dst) == 64;
    let r = rex(wide, -1, -1, dst.n);
    if (fits8(v)) {
        let b = concat([131, modrm(3, ext, dst.n)], [u8(v)]);
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        let b = concat([129, modrm(3, ext, dst.n)], le32(v));
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_shl(dst, v: long) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // shl $imm8, %r64
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "shl dst" }
    } else if (op_size(dst) != 64) {
        { bytes: [], fix: [], err: "shl dst" }
    } else if (v < 0) {
        { bytes: [], fix: [], err: "shl count range" }
    } else if (v > 63) {
        { bytes: [], fix: [], err: "shl count range" }
    } else {
        let r = rex(true, -1, -1, dst.n);
        let b = concat([193, modrm(3, 4, dst.n)], [u8(v)]);
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_shr(dst, v: long) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // shr $imm8, %r64 (logical, for unsigned divide-by-pow2)
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "shr dst" }
    } else if (op_size(dst) != 64) {
        { bytes: [], fix: [], err: "shr dst" }
    } else if (v < 0) {
        { bytes: [], fix: [], err: "shr count range" }
    } else if (v > 63) {
        { bytes: [], fix: [], err: "shr count range" }
    } else {
        let r = rex(true, -1, -1, dst.n);
        let b = concat([193, modrm(3, 5, dst.n)], [u8(v)]);
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

// ── SSE scalar-double encodings ────────────────────────────────────────
// Floats travel in %rax as their raw IEEE754 bits; only arithmetic and
// comparison move them into %xmmN, so the rest of the backend (slots,
// pushes, calls) is unchanged.

def enc_sse_arith(mn: str, dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // F2 0F <op> /r  — addsd 58, subsd 5C, mulsd 59, divsd 5E
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "sse dst" }
    } else if (src.k != "reg") {
        { bytes: [], fix: [], err: "sse src" }
    } else {
        let op = 88;
        if (mn == "subsd") { op = 92; 0; } else { 0; };
        if (mn == "mulsd") { op = 89; 0; } else { 0; };
        if (mn == "divsd") { op = 94; 0; } else { 0; };
        let r = rex(false, dst.n, -1, src.n);
        let tail = [15, op, modrm(3, dst.n, src.n)];
        if (r < 0) {
            { bytes: concat([242], tail), fix: [], err: "" }
        } else {
            { bytes: concat([242, r], tail), fix: [], err: "" }
        }
    }
};

def enc_ucomisd(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // 66 0F 2E /r
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "ucomisd dst" }
    } else if (src.k != "reg") {
        { bytes: [], fix: [], err: "ucomisd src" }
    } else {
        let r = rex(false, dst.n, -1, src.n);
        let tail = [15, 46, modrm(3, dst.n, src.n)];
        if (r < 0) {
            { bytes: concat([102], tail), fix: [], err: "" }
        } else {
            { bytes: concat([102, r], tail), fix: [], err: "" }
        }
    }
};

def enc_cvtsi2sd(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // F2 REX.W 0F 2A /r  — cvtsi2sd %gpr, %xmm
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "cvtsi2sd dst" }
    } else if (src.k != "reg") {
        { bytes: [], fix: [], err: "cvtsi2sd src" }
    } else {
        let r = rex(true, dst.n, -1, src.n);
        { bytes: concat([242, r], [15, 42, modrm(3, dst.n, src.n)]), fix: [], err: "" }
    }
};

def enc_cvttsd2si(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // F2 REX.W 0F 2C /r  — cvttsd2si %xmm, %gpr (truncating)
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "cvttsd2si dst" }
    } else if (src.k != "reg") {
        { bytes: [], fix: [], err: "cvttsd2si src" }
    } else {
        let r = rex(true, dst.n, -1, src.n);
        { bytes: concat([242, r], [15, 44, modrm(3, dst.n, src.n)]), fix: [], err: "" }
    }
};

def enc_movq(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // 66 REX.W 0F 6E /r  — movq %gpr, %xmm   (gpr -> xmm)
    // 66 REX.W 0F 7E /r  — movq %xmm, %gpr   (xmm -> gpr)
    if (dst.k != "reg") {
        { bytes: [], fix: [], err: "movq dst" }
    } else if (src.k != "reg") {
        { bytes: [], fix: [], err: "movq src" }
    } else if (op_size(dst) == 128) {
        // into an xmm: the xmm is the reg field, the gpr the rm field
        let r = rex(true, dst.n, -1, src.n);
        { bytes: concat([102, r], [15, 110, modrm(3, dst.n, src.n)]), fix: [], err: "" }
    } else {
        // out of an xmm: the xmm is still the reg field
        let r = rex(true, src.n, -1, dst.n);
        { bytes: concat([102, r], [15, 126, modrm(3, src.n, dst.n)]), fix: [], err: "" }
    }
};

def enc_imul(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (dst.k == "reg" && op_size(dst) == 64 && src.k == "reg" && op_size(src) == 64) {
        let r = rex(true, dst.n, -1, src.n);
        let b = [15, 175, modrm(3, dst.n, src.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "imul form" }
    }
};

def enc_unary(op: str, o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // NOTE: nested ifs, not `||` (see reg_num note above).
    if (o.k != "reg") {
        { bytes: [], fix: [], err: "unary form" }
    } else if (op_size(o) != 64) {
        { bytes: [], fix: [], err: "unary form" }
    } else {
        let ext = 3;
        let opc = 247;
        if (op == "idiv") { ext = 7; 0; }
        else if (op == "div") { ext = 6; 0; }
        else if (op == "dec") { ext = 1; opc = 255; 0; }
        else if (op == "inc") { ext = 0; opc = 255; 0; }
        else { 0 };
        let r = rex(true, -1, -1, o.n);
        let b = [opc, modrm(3, ext, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_jmp(o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (o.k != "lbl") {
        { bytes: [], fix: [], err: "jmp target" }
    } else {
        { bytes: [233, 0, 0, 0, 0], fix: [fixup(1, "rel32", o.name, "")], err: "" }
    }
};

def enc_call(o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (o.k == "ind") {
        // call *%reg — FF /2, used for closure code pointers.
        let r = rex(false, 0, -1, o.n);
        let b = [255, modrm(3, 2, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    } else if (o.k != "lbl") {
        { bytes: [], fix: [], err: "call target" }
    } else {
        { bytes: [232, 0, 0, 0, 0], fix: [fixup(1, "rel32", o.name, "")], err: "" }
    }
};

def enc_jcc(code: long, o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (o.k != "lbl") {
        { bytes: [], fix: [], err: "jcc target" }
    } else {
        { bytes: [15, code, 0, 0, 0, 0], fix: [fixup(2, "rel32", o.name, "")], err: "" }
    }
};

def enc_setcc(code: long, o) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (o.k != "reg" || op_size(o) != 8) {
        { bytes: [], fix: [], err: "setcc form" }
    } else {
        let r = rex(false, -1, -1, o.n);
        let b = [15, code, modrm(3, 0, o.n)];
        { bytes: with_rex(r, b), fix: [], err: "" }
    }
};

def enc_cmpb(v: long, m) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    if (m.k != "mem") {
        { bytes: [], fix: [], err: "cmpb form" }
    } else {
        let t = mem_tail(m, 7);
        let r = rex_rm(false, 7, m);
        let b = concat(concat([128, t.modrm], t.extra), [u8(v)]);
        enc_mem_result(r, b, t)
    }
};

def enc_movb_reg(dst, src) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
    // movb %r8 -> mem8 (single-byte stores for string data)
    if (dst.k == "mem" && src.k == "reg" && op_size(src) == 8) {
        let t = mem_tail(dst, src.n);
        let r = rex_rm(false, src.n, dst);
        let b = concat([136, t.modrm], t.extra);
        enc_mem_result(r, b, t)
    } else {
        { bytes: [], fix: [], err: "movb reg form" }
    }
};

// ── mnemonic dispatch ──────────────────────────────────────────────────

def need1(mn: str, ops) -> str {
    if (len(ops) != 1) { mn + " takes 1 operand" } else { "" }
};

def need2(mn: str, ops) -> str {
    if (len(ops) != 2) { mn + " takes 2 operands" } else { "" }
};

def enc_insn(mn: str, ops) -> {bytes: [long], fix: [{off: long, kind: str, lbl: str, lbl2: str}], err: str} {
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
        } else if (ops[0].k == "imm") {
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
    } else if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or" || mn == "test") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else {
            let dst = ops[1];
            let src = ops[0];
            if (src.k == "imm") {
                if (mn == "add" || mn == "sub" || mn == "cmp" || mn == "xor" || mn == "and" || mn == "or") {
                    enc_alu_imm(mn, dst, src.v)
                } else {
                    { bytes: [], fix: [], err: mn + " imm form" }
                }
            } else if (dst.k == "reg" && src.k == "reg" && mn == "xor" && op_size(dst) == 32 && op_size(src) == 32) {
                enc_xor32(dst, src)
            } else {
                enc_arith(mn, dst, src)
            }
        }
    } else if (mn == "shl") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else if (ops[0].k != "imm") {
            { bytes: [], fix: [], err: "shl needs imm" }
        } else {
            enc_shl(ops[1], ops[0].v)
        }
    } else if (mn == "shr") {
        let e = need2(mn, ops);
        if (e != "") {
            { bytes: [], fix: [], err: e }
        } else if (ops[0].k != "imm") {
            { bytes: [], fix: [], err: "shr needs imm" }
        } else {
            enc_shr(ops[1], ops[0].v)
        }
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
    } else if (mn == "neg" || mn == "idiv" || mn == "div" || mn == "dec" || mn == "inc") {
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
        } else if (ops[0].k != "imm") {
            { bytes: [], fix: [], err: "cmpb needs imm" }
        } else {
            enc_cmpb(ops[0].v, ops[1])
        }
    } else if (mn == "cqo") {
        { bytes: [72, 153], fix: [], err: "" }
    } else if (mn == "syscall") {
        { bytes: [15, 5], fix: [], err: "" }
    } else if (mn == "ret") {
        { bytes: [195], fix: [], err: "" }
    } else {
        { bytes: [], fix: [], err: "unknown mnemonic '" + mn + "'" }
    }
};

export { r64, reg_num, reg_size, enc_insn, concat, fixup, byte_at, le16, le32, le64 };
