// AArch64 lowering of the shared machine IR. The Y stack convention and value
// layouts stay identical to packed units; x28 is its byte-addressed stack.
// x16..x27 and x30 belong to lowering. Linux sees a separate aligned SP.
import tags from "./tags.y";
import xenc from "./enc64.y";

type A64Code = { bytes: [byte], fix: [Fixup], err: str };

// Lazy sealed code can fault between any two instructions. Keep Linux's SP
// below the live Y stack so its signal frame cannot overwrite Y frames.
let a64_signals = false;
def set_signals(on: bool) -> void { a64_signals = on; };
def a64_sync_sp(c: A64Code) -> A64Code {
    if (!a64_signals) { return c; };
    c = a64_imm(c, 27, 15);
    c = a64_word(c, 0x8a3b039b); // bic x27, x28, x27
    c = a64_word(c, 0xd104037b); // sub x27, x27, #256
    a64_word(c, 0x9100037f) // mov sp, x27
};

def a64_new() -> A64Code { { bytes: [], fix: [], err: "" } };
def a64_word(c: A64Code, w: long) -> A64Code {
    c.bytes += xenc.le32(w);
    c
};
// Resolve a local conditional branch after emitting a variable-length sequence.
def a64_end(c: A64Code, at: long) -> A64Code {
    let w = 0;
    for i in 0..4 { w |= c.bytes[at + i] << (i * 8); };
    w = (w & 0xff00001f) | (((len(c.bytes) - at) / 4) << 5);
    let b = xenc.le32(w);
    for i in 0..4 { c.bytes[at + i] = b[i]; };
    c
};
def a64_reg(n: long) -> long {
    if (n == 4) { 28 } else if (n == 5) { 29 } else { n }
};
def a64_mov(c: A64Code, d: long, s: long) -> A64Code {
    a64_word(c, 0xaa0003e0 | (s << 16) | d)
};
def a64_imm(c: A64Code, d: long, v: long) -> A64Code {
    c = a64_word(c, 0xd2800000 | ((v & 65535) << 5) | d);
    for i in 1..4 {
        if (((v >>> (16 * i)) & 65535) != 0) {
            c = a64_word(c, 0xf2800000 | (i << 21) | (((v >>> (16 * i)) & 65535) << 5) | d);
        };
    };
    c
};
def a64_addr(c: A64Code, d: long, name: str) -> A64Code {
    c.fix += { off: len(c.bytes), kind: "a64addr", lbl: name, lbl2: "" };
    c = a64_word(c, 0xd2800000 | d);
    for i in 1..4 { c = a64_word(c, 0xf2800000 | (i << 21) | d); };
    c
};
def a64_branch(c: A64Code, name: str, link: bool) -> A64Code {
    c.fix += { off: len(c.bytes), kind: "a64branch", lbl: name, lbl2: "" };
    a64_word(c, if (link) { 0x94000000 } else { 0x14000000 })
};
def a64_memaddr(c: A64Code, o: Operand) -> A64Code {
    if (o.rip) {
        c = a64_addr(c, 18, o.lbl);
    } else if (o.k == K.fs) {
        c = a64_word(c, 0xd53bd052); // mrs x18, tpidr_el0
        if (o.disp != 0) {
            c = a64_imm(c, 17, o.disp);
            c = a64_word(c, 0x8b110252);
        };
    } else {
        c = a64_mov(c, 18, a64_reg(o.base));
        if (o.idx >= 0) {
            let shift = if (o.scale == 8) { 3 } else if (o.scale == 4) { 2 } else if (o.scale == 2) { 1 } else { 0 };
            c = a64_word(c, 0x8b000000 | (a64_reg(o.idx) << 16) | (shift << 10) | (18 << 5) | 18);
        };
        if (o.disp != 0) {
            c = a64_imm(c, 17, o.disp);
            c = a64_word(c, 0x8b110252);
        };
    };
    c
};
def a64_load(c: A64Code, o: Operand, d: long, size: long) -> A64Code {
    if (o.k == K.reg || o.k == K.ind) {
        c = a64_mov(c, d, a64_reg(o.n));
    } else if (o.k == K.imm) {
        c = a64_imm(c, d, o.v);
    } else if (o.k == K.diff) {
        c.fix += { off: len(c.bytes), kind: "a64diff", lbl: o.a, lbl2: o.b };
        c = a64_word(c, 0xd2800000 | d);
        for i in 1..4 { c = a64_word(c, 0xf2800000 | (i << 21) | d); };
    } else {
        c = a64_memaddr(c, o);
        let op = if (size == 8) { 0x39400000 } else if (size == 16) { 0x79400000 } else if (size == 32) { 0xb9400000 } else { 0xf9400000 };
        c = a64_word(c, op | (18 << 5) | d);
    };
    c
};
def a64_store(c: A64Code, o: Operand, s: long, size: long) -> A64Code {
    if (o.k == K.reg) {
        let d = a64_reg(o.n);
        if (size == 8 || size == 16) {
            c = a64_word(c, 0xb3400000 | ((size - 1) << 10) | (s << 5) | d);
        } else if (size == 32) {
            c = a64_word(c, 0x2a0003e0 | (s << 16) | d);
        } else { c = a64_mov(c, d, s); };
        if (d == 28) { c = a64_sync_sp(c); };
    } else {
        c = a64_memaddr(c, o);
        let op = if (size == 8) { 0x39000000 } else if (size == 16) { 0x79000000 } else if (size == 32) { 0xb9000000 } else { 0xf9000000 };
        c = a64_word(c, op | (18 << 5) | s);
    };
    c
};
// Canonical x86 carry in x24; x25 retains the result for parity tests.
def a64_carry(c: A64Code, cond: long) -> A64Code {
    a64_word(c, 0x9a9f07f8 | ((cond ^ 1) << 12))
};
def a64_condition(c: A64Code, name: str) -> A64Code {
    let cc = 0;
    if (name in ["e", "z"]) { cc = 0; }
    else if (name in ["ne", "nz"]) { cc = 1; }
    else if (name == "s") { cc = 4; }
    else if (name == "ns") { cc = 5; }
    else if (name == "ge") { cc = 10; }
    else if (name == "l") { cc = 11; }
    else if (name == "g") { cc = 12; }
    else if (name == "le") { cc = 13; }
    else if (name == "o") { cc = 6; }
    else if (name == "no") { cc = 7; }
    else if (name in ["b", "c", "nae", "ae", "nc", "nb"]) {
        c = a64_mov(c, 16, 24);
        if (name in ["ae", "nc", "nb"]) {
            c = a64_imm(c, 17, 1);
            c = a64_word(c, 0xca110210);
        };
        return c;
    } else if (name == "a" || name == "be") {
        c = a64_word(c, 0x9a9f07f0 | (0 << 12)); // cset x16, ne
        c = a64_word(c, 0x8a380210); // bic x16, x16, x24
        if (name == "be") {
            c = a64_imm(c, 17, 1);
            c = a64_word(c, 0xca110210);
        };
        return c;
    } else if (name == "p" || name == "np") {
        c = a64_mov(c, 16, 25);
        for i in 0..3 {
            let shift = if (i == 0) { 4 } else if (i == 1) { 2 } else { 1 };
            c = a64_word(c, 0xca000000 | (16 << 16) | (1 << 22) | (shift << 10) | (16 << 5) | 16);
        };
        c = a64_imm(c, 17, 1);
        if (name == "p") { c = a64_word(c, 0xca110210); };
        return a64_word(c, 0x8a110210);
    } else {
        return { ...c, err: "unsupported AArch64 condition '" + name + "'" };
    };
    a64_word(c, 0x9a9f07f0 | ((cc ^ 1) << 12))
};
def a64_size(mn: str, ops: [Operand]) -> long {
    if (mn in ["movb", "cmpb", "testb", "addb", "subb"]) { return 8; };
    if (mn in ["movw", "movzwq", "movswq"]) { return 16; };
    if (mn in ["movl", "movslq"]) { return 32; };
    foreach (o in ops) { if (o.k == K.reg && o.size < 128) { return o.size; }; };
    64
};
def a64_encode(mn: str, ops: [Operand]) -> A64Code {
    let c = a64_new();
    let n = len(ops);
    let size = a64_size(mn, ops);
    if (mn in ["shl", "sal", "shr", "sar"]) { size = ops[1].size; };
    if (mn == "a64_signal_entry") {
        c = a64_word(c, 0x910003fc); // handler stack starts below the signal frame
        c = a64_mov(c, 7, 0);
        c = a64_mov(c, 6, 1);
        c = a64_addr(c, 16, "y_obf_restorer");
        c = a64_word(c, 0xf81f8f90);
        return a64_sync_sp(c);
    };
    if (mn == "a64_sigreturn") {
        c = a64_word(c, 0x9100039f); // restore the kernel's signal-frame SP
        c = a64_imm(c, 8, 139);
        return a64_word(c, 0xd4000001);
    };
    if (mn == "a64_cache_begin") { return a64_mov(c, 26, 7); };
    if (mn == "a64_cache_end") {
        // Four-byte steps cover every possible cache-line size. Neither loop
        // executes the freshly decoded code before D/I cache synchronization.
        c = a64_mov(c, 16, 26);
        c = a64_word(c, 0xd50b7b30); // dc cvau, x16
        c = a64_word(c, 0x91001210); // add x16, x16, #4
        c = a64_word(c, 0xeb07021f); // cmp x16, x7
        c = a64_word(c, 0x54ffffa3); // b.lo .-12
        c = a64_word(c, 0xd5033b9f); // dsb ish
        c = a64_mov(c, 16, 26);
        c = a64_word(c, 0xd50b7530); // ic ivau, x16
        c = a64_word(c, 0x91001210);
        c = a64_word(c, 0xeb07021f);
        c = a64_word(c, 0x54ffffa3);
        c = a64_word(c, 0xd5033b9f);
        return a64_word(c, 0xd5033fdf); // isb
    };
    if (mn == "a64_entry") {
        return a64_word(c, 0x910003fc); // mov x28, sp
    };
    if (mn == "a64_runtime") { return a64_runtime(); };
    if (mn == "a64_raw") { return a64_syscall_body(true); };
    if (mn == "a64_mapped") { return a64_syscall_body(false); };
    if (mn == "syscall") { return a64_branch(c, "y_a64_syscall", true); };
    if (mn == "nop" || mn == "pause") { return a64_word(c, 0xd503201f); };
    if (mn == "ud2" || mn == "int3") { return a64_word(c, 0xd4200000); };
    if (mn == "ret") {
        c = a64_word(c, 0xf8408790); // ldr x16, [x28], #8
        if (n > 0) {
            c = a64_imm(c, 17, ops[0].v);
            c = a64_word(c, 0x8b11039c);
        };
        c = a64_sync_sp(c);
        return a64_word(c, 0xd61f0200);
    };
    if (mn == "push") {
        c = a64_load(c, ops[0], 16, 64);
        c = a64_word(c, 0xf81f8f90); // str x16, [x28, #-8]!
        return a64_sync_sp(c);
    };
    if (mn == "pop") {
        c = a64_word(c, 0xf8408790);
        c = a64_sync_sp(c);
        return a64_store(c, ops[0], 16, 64);
    };
    if (mn == "call") {
        if (ops[0].name == "y_a64_raw_syscall") { return a64_branch(c, "y_a64_raw_syscall", true); };
        if (ops[0].k == K.ind) { c = a64_mov(c, 20, a64_reg(ops[0].n)); };
        c = a64_word(c, if (a64_signals) { 0x100000f0 } else { 0x10000070 }); // adr x16, return PC
        c = a64_word(c, 0xf81f8f90);
        c = a64_sync_sp(c);
        if (ops[0].k == K.ind) { return a64_word(c, 0xd61f0280); };
        return a64_branch(c, ops[0].name, false);
    };
    if (mn == "jmp") {
        if (ops[0].k == K.ind) { return a64_word(c, 0xd61f0000 | (a64_reg(ops[0].n) << 5)); };
        return a64_branch(c, ops[0].name, false);
    };
    if (mn[:1] == "j") {
        c = a64_condition(c, mn[1:]);
        c = a64_word(c, 0xb4000050); // cbz x16, .+8
        return a64_branch(c, ops[0].name, false);
    };
    if (mn[:3] == "set") {
        c = a64_condition(c, mn[3:]);
        return a64_store(c, ops[0], 16, 8);
    };
    if (mn == "lea") {
        c = a64_memaddr(c, ops[0]);
        return a64_store(c, ops[1], 18, 64);
    };
    if (mn in ["mov", "movq", "movb", "movw", "movl", "movzbq", "movzwq", "movsbq", "movswq", "movslq"]) {
        if (mn == "movq" && (ops[0].size == 128 || ops[1].size == 128)) {
            if (ops[0].size == 128 && ops[1].size == 128) {
                return a64_word(c, 0x1e604000 | (ops[0].n << 5) | ops[1].n);
            };
            if (ops[0].size == 128) {
                return a64_word(c, 0x9e660000 | (ops[0].n << 5) | a64_reg(ops[1].n));
            };
            return a64_word(c, 0x9e670000 | (a64_reg(ops[0].n) << 5) | ops[1].n);
        };
        if (mn == "movzbq" || mn == "movsbq") { size = 8; };
        c = a64_load(c, ops[0], 16, size);
        let extend = mn in ["movzbq", "movzwq", "movsbq", "movswq", "movslq"];
        if (extend) {
            let op = if (mn in ["movsbq", "movswq", "movslq"]) { 0x93400000 } else { 0xd3400000 };
            c = a64_word(c, op | ((size - 1) << 10) | (16 << 5) | 16);
        };
        return a64_store(c, ops[1], 16, if (extend) { 64 } else { size });
    };
    if (mn == "cqo") { return a64_word(c, 0x937ffc02); }; // asr x2, x0, #63
    if (mn == "bswapq" || mn == "bswapl") {
        let r = a64_reg(ops[0].n);
        return a64_word(c, (if (mn == "bswapq") { 0xdac00c00 } else { 0x5ac00800 }) | (r << 5) | r);
    };
    if (mn == "bsr") {
        c = a64_load(c, ops[0], 16, 64);
        c = a64_word(c, 0xdac01210); // clz x16, x16
        c = a64_imm(c, 17, 63);
        c = a64_word(c, 0xcb100230);
        return a64_store(c, ops[1], 16, 64);
    };
    if (mn in ["div", "idiv"]) {
        c = a64_load(c, ops[0], 16, size);
        c = a64_word(c, 0xb5000050); // cbnz divisor, .+8
        c = a64_word(c, 0xd4200000);
        let op = if (mn == "div") { 0x9ac00800 } else { 0x9ac00c00 };
        c = a64_word(c, op | (16 << 16) | 17);
        c = a64_word(c, 0x9b008000 | (16 << 16) | (0 << 10) | (17 << 5) | 2); // msub remainder
        return a64_mov(c, 0, 17);
    };
    if (mn in ["neg", "not", "inc", "dec"]) {
        c = a64_load(c, ops[0], 16, size);
        if (mn == "not") { c = a64_word(c, 0xaa3003f0); }
        else if (mn == "neg") { c = a64_word(c, 0xeb1003f0); c = a64_carry(c, 3); }
        else { c = a64_word(c, if (mn == "inc") { 0xb1000610 } else { 0xf1000610 }); };
        if (mn != "not") { c = a64_mov(c, 25, 16); };
        return a64_store(c, ops[0], 16, size);
    };
    if (mn == "xchg") {
        c = a64_memaddr(c, ops[1]);
        let r = a64_reg(ops[0].n);
        c = a64_word(c, 0xd5033bbf); // dmb ish
        c = a64_word(c, 0xc85ffe50); // ldaxr x16, [x18]
        c = a64_word(c, 0xc811fc00 | (18 << 5) | r); // stlxr w17, r, [x18]
        c = a64_word(c, 0x35ffffd1); // cbnz w17, .-8
        c = a64_word(c, 0xd5033bbf);
        return a64_mov(c, r, 16);
    };
    if (mn in ["shl", "sal", "shr", "sar"]) {
        c = a64_load(c, ops[1], 20, size);
        c = a64_load(c, ops[0], 16, 64);
        c = a64_imm(c, 17, if (size == 32) { 31 } else { 63 });
        c = a64_word(c, 0x8a110210);
        let zero = len(c.bytes);
        c = a64_word(c, 0xb4000010); // count zero preserves all flags
        // The carry is the last bit shifted out.
        if (mn == "shl" || mn == "sal") {
            c = a64_imm(c, 17, size);
            c = a64_word(c, 0xcb100231); // sub x17, x17, x16
        } else {
            c = a64_word(c, 0xd1000611); // sub x17, x16, #1
        };
        c = a64_word(c, 0x9ad12698); // lsrv x24, x20, x17
        c = a64_imm(c, 17, 1);
        c = a64_word(c, 0x8a110318);
        let op = if (mn == "shl" || mn == "sal") { 0x9ac02000 } else if (mn == "shr") { 0x9ac02400 } else { 0x9ac02800 };
        if (size == 32) { op &= 0x7fffffff; };
        c = a64_word(c, op | (16 << 16) | (20 << 5) | 20);
        c = a64_word(c, if (size == 32) { 0x6a14029f } else { 0xea14029f });
        c = a64_mov(c, 25, 20);
        c = a64_end(c, zero);
        return a64_store(c, ops[1], 20, size);
    };
    if (mn in ["add", "sub", "cmp", "cmpq", "cmpb", "and", "or", "xor", "test", "testq", "testb", "imul"]) {
        c = a64_load(c, ops[1], 20, size);
        c = a64_load(c, ops[0], 16, size);
        let op = 0;
        if (mn == "add") { op = 0xab000000; }
        else if (mn in ["sub", "cmp", "cmpq", "cmpb"]) { op = 0xeb000000; }
        else if (mn in ["and", "test", "testq", "testb"]) { op = 0xea000000; }
        else if (mn == "or") { op = 0xaa000000; }
        else if (mn == "xor") { op = 0xca000000; }
        else { op = 0x9b007c00; };
        if (size <= 32) { op &= 0x7fffffff; };
        c = a64_word(c, op | (16 << 16) | (20 << 5) | 20);
        if (mn in ["or", "xor", "imul"]) {
            c = a64_word(c, (if (size <= 32) { 0x6a14029f } else { 0xea14029f }));
        };
        c = a64_mov(c, 25, 20);
        if (mn == "add") { c = a64_carry(c, 2); }
        else if (mn in ["sub", "cmp", "cmpq", "cmpb"]) { c = a64_carry(c, 3); }
        else { c = a64_imm(c, 24, 0); };
        if (!(mn in ["cmp", "cmpq", "cmpb", "test", "testq", "testb"])) {
            c = a64_store(c, ops[1], 20, size);
        };
        return c;
    };
    if (mn in ["movsd", "addsd", "subsd", "mulsd", "divsd", "sqrtsd", "ucomisd", "cvtsi2sd", "cvttsd2si", "xorpd", "andpd", "orpd"]) {
        return a64_float(c, mn, ops);
    };
    { ...c, err: "unsupported AArch64 instruction '" + mn + "'" }
};

def a64_nan(c: A64Code, source: long, dest: long) -> A64Code {
    c = a64_word(c, 0xd53b4217); // mrs x23, nzcv
    c = a64_word(c, 0x1e602000 | (dest << 16) | (dest << 5));
    let finite = len(c.bytes);
    c = a64_word(c, 0x54000007); // b.vc end
    c = a64_word(c, 0x1e7e23c0); // fcmp d30, d30 (original destination)
    let old_nan = len(c.bytes);
    c = a64_word(c, 0x54000006);
    c = a64_word(c, 0x1e602000 | (source << 16) | (source << 5));
    let src_nan = len(c.bytes);
    c = a64_word(c, 0x54000006);
    c = a64_imm(c, 16, -2251799813685248); // x86's invalid-operation NaN
    c = a64_word(c, 0x9e670000 | (16 << 5) | dest);
    c = a64_end(c, finite);
    c = a64_end(c, old_nan);
    c = a64_end(c, src_nan);
    a64_word(c, 0xd51b4217)
};

def a64_float(c: A64Code, mn: str, ops: [Operand]) -> A64Code {
    let s = ops[0];
    let d = ops[1];
    let sr = s.n;
    if (mn == "cvtsi2sd") {
        c = a64_load(c, s, 16, 64);
        return a64_word(c, 0x9e620000 | (16 << 5) | d.n);
    };
    if (mn == "cvttsd2si") {
        c = a64_word(c, 0xd53b4214);
        c = a64_word(c, 0x9e660010 | (s.n << 5));
        c = a64_imm(c, 17, 0x7fffffffffffffff);
        c = a64_word(c, 0x8a110210);
        c = a64_imm(c, 17, 0x43e0000000000000);
        c = a64_word(c, 0xeb11021f);
        c = a64_word(c, 0x9e780000 | (s.n << 5) | a64_reg(d.n));
        c = a64_imm(c, 16, -9223372036854775808);
        c = a64_word(c, 0x9a800000 | (a64_reg(d.n) << 16) | (2 << 12) | (16 << 5) | a64_reg(d.n));
        return a64_word(c, 0xd51b4214);
    };
    if (s.k == K.mem) {
        c = a64_memaddr(c, s);
        c = a64_word(c, 0xfd400000 | (18 << 5) | 31);
        sr = 31;
    };
    if (mn == "movsd") {
        if (d.k == K.mem) {
            c = a64_memaddr(c, d);
            return a64_word(c, 0xfd000000 | (18 << 5) | sr);
        };
        return a64_word(c, 0x1e604000 | (sr << 5) | d.n);
    };
    if (mn == "sqrtsd") {
        c = a64_word(c, 0x1e60401e | (sr << 5));
        c = a64_word(c, 0x1e61c000 | (sr << 5) | d.n);
        return a64_nan(c, 30, d.n);
    };
    if (mn == "ucomisd") {
        c = a64_word(c, 0x1e602000 | (sr << 16) | (d.n << 5));
        c = a64_carry(c, 3);
        // Unordered: x86 ZF=PF=CF=1; ARM has V=1, Z=0, C=1.
        c = a64_word(c, 0x9a9f77f0); // cset x16, vs
        c = a64_word(c, 0xaa100318); // orr x24, x24, x16
        c = a64_word(c, 0x9a9f67f9); // cset x25, vc
        c = a64_word(c, 0x540000a7); // b.vc .+20
        c = a64_imm(c, 16, 0x60000000);
        c = a64_word(c, 0xd51b4210); // msr nzcv, x16 (Z=C=1)
        c = a64_word(c, 0xd503201f);
        return c;
    };
    let op = if (mn == "addsd") { 0x1e602800 } else if (mn == "subsd") { 0x1e603800 }
        else if (mn == "mulsd") { 0x1e600800 } else if (mn == "divsd") { 0x1e601800 }
        else if (mn == "xorpd") { 0x6e201c00 } else if (mn == "andpd") { 0x4e201c00 } else { 0x4ea01c00 };
    let arithmetic = mn in ["addsd", "subsd", "mulsd", "divsd"];
    if (arithmetic) { c = a64_word(c, 0x1e60401e | (d.n << 5)); };
    // Preserve a source that is also the destination before the operation.
    if (arithmetic && sr == d.n) { sr = 30; };
    c = a64_word(c, op | (sr << 16) | (d.n << 5) | d.n);
    if (arithmetic) { c = a64_nan(c, sr, d.n); };
    c
};

// Runtime syscall numbers are the shared IR's x86 Linux numbers. Only this
// boundary translates them; a user's syscall() already names AArch64 numbers.
def a64_runtime() -> A64Code {
    let c = a64_new();
    c = a64_word(c, 0xd53b4213); // preserve flags before dispatch
    c = a64_word(c, 0xf102781f); // cmp x0, #158: ARCH_SET_FS
    c = a64_word(c, 0x540000a1);
    c = a64_word(c, 0xd51bd046); // msr tpidr_el0, x6
    c = a64_imm(c, 0, 0);
    c = a64_word(c, 0xd51b4213);
    c = a64_word(c, 0xd65f03c0);
    let old = [0,1,3,8,9,10,11,12,16,17,19,20,24,25,28,32,35,39,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,60,61,62,63,72,73,74,75,79,80,81,95,96,97,98,99,100,102,104,107,108,110,111,112,131,157,186,202,217,218,228,230,231,232,233,234,257,258,260,262,263,264,267,268,269,270,271,273,274,278,281,288,291,293,294,295,296,302,316,318,319,322,332];
    let nums = [63,64,57,62,222,226,215,214,29,67,65,66,124,216,233,23,101,172,198,203,202,206,207,211,212,210,200,201,204,205,199,208,209,93,260,129,160,25,32,82,83,17,49,50,166,169,163,165,179,153,174,176,175,177,173,154,156,132,167,178,98,61,96,113,115,94,22,21,131,56,34,54,79,35,38,78,53,48,72,73,99,100,76,22,242,20,59,26,69,70,261,276,278,279,281,291];
    old += [59, 13, 15, 101]; nums += [221, 134, 139, 117];
    for i in 0..len(old) {
        c = a64_word(c, 0xf100001f | (old[i] << 10)); // cmp x0, old
        c = a64_word(c, 0x54000061); // b.ne .+12
        c = a64_imm(c, 21, nums[i]);
        c = a64_branch(c, "y_a64_mapped_syscall", false);
    };
    // The missing legacy calls need their argument conventions adapted.
    foreach (nr in [57, 56, 22, 33, 7]) {
        c = a64_word(c, 0xf100001f | (nr << 10));
        c = a64_word(c, 0x54000061);
        c = a64_imm(c, 21, if (nr == 57 || nr == 56) { 220 } else if (nr == 22) { 59 } else if (nr == 33) { 24 } else { 73 });
        c = a64_branch(c, "y_a64_mapped_syscall", false);
    };
    c = a64_imm(c, 0, -38); // ENOSYS, never issue an unrelated syscall
    c = a64_word(c, 0xd51b4213);
    a64_word(c, 0xd65f03c0)
};

def a64_syscall_body(raw: bool) -> A64Code {
    let c = a64_new();
    if (raw) {
        c = a64_word(c, 0xd53b4213);
        c = a64_mov(c, 21, 0);
    };
    // Keep the kernel stack below the live Y stack and aligned to 16 bytes.
    c = a64_imm(c, 16, -16);
    c = a64_word(c, 0x8a100390); // and x16, x28, x16
    c = a64_word(c, 0xd1040210); // sub x16, x16, #256
    c = a64_word(c, 0x9100021f); // mov sp, x16
    for i in 1..16 { c = a64_word(c, 0xf90003e0 | (i << 10) | i); };
    c = a64_mov(c, 8, 21);
    c = if (raw) { a64_imm(c, 22, -1) } else { a64_mov(c, 22, 0) }; // original legacy call number
    c = a64_mov(c, 0, 7);
    c = a64_mov(c, 1, 6);
    c = a64_mov(c, 3, 10);
    c = a64_word(c, 0xf94023e4); // original x8, arg5
    c = a64_mov(c, 5, 9);
    // Special adapters selected by the original runtime number. Raw calls
    // arrive with x22=-1, so their AArch64 arguments are untouched.
    c = a64_word(c, 0xf100001f | (57 << 10) | (22 << 5));
    c = a64_word(c, 0x540000c1);
    c = a64_imm(c, 0, 17); // clone(SIGCHLD, 0, 0, 0, 0)
    for i in 1..5 { c = a64_imm(c, i, 0); };
    c = a64_word(c, 0xf100001f | (22 << 10) | (22 << 5));
    c = a64_word(c, 0x54000041);
    c = a64_imm(c, 1, 0); // pipe2 flags
    c = a64_word(c, 0xf100001f | (33 << 10) | (22 << 5));
    c = a64_word(c, 0x54000041);
    c = a64_imm(c, 2, 0); // dup3 flags
    // Linux AArch64 assigns O_DIRECTORY/O_NOFOLLOW and O_DIRECT/O_LARGEFILE
    // to the opposite pairs of bits. Preserve the std pack's open flag ABI.
    c = a64_word(c, 0xf10406df); // cmp x22, #257
    let skip_open = len(c.bytes);
    c = a64_word(c, 0x54000001);
    c = a64_mov(c, 16, 2);
    c = a64_imm(c, 17, -245761);
    c = a64_word(c, 0x8a110042);
    for i in 14..18 {
        c = a64_word(c, 0xd3400000 | (i << 16) | (i << 10) | (16 << 5) | 17);
        let dest = if (i < 16) { i + 2 } else { i - 2 };
        c = a64_word(c, 0xaa110042 | (dest << 10));
    };
    c = a64_end(c, skip_open);
    // poll(2) is ppoll(2) on AArch64; convert milliseconds to timespec.
    c = a64_word(c, 0xf1001edf); // cmp x22, #7
    let skip_poll = len(c.bytes);
    c = a64_word(c, 0x54000001);
    c = a64_imm(c, 3, 0);
    c = a64_imm(c, 4, 0);
    c = a64_word(c, 0xb6f80082); // tbz x2, #63, .+16
    c = a64_imm(c, 2, 0);
    let infinite = len(c.bytes);
    c = a64_word(c, 0xb4000002); // cbz x2, end (infinite)
    c = a64_word(c, 0xd503201f);
    c = a64_imm(c, 17, 1000);
    c = a64_word(c, 0x9ad10c50); // sdiv x16, x2, x17
    c = a64_word(c, 0xf90043f0); // seconds
    c = a64_word(c, 0x9b118a14); // msub x20, x16, x17, x2
    c = a64_imm(c, 17, 1000000);
    c = a64_word(c, 0x9b117e94);
    c = a64_word(c, 0xf90047f4);
    c = a64_word(c, 0x910203e2); // add x2, sp, #128
    c = a64_end(c, infinite);
    c = a64_end(c, skip_poll);
    // clone uses (flags, stack, parent_tid, tls, child_tid) on AArch64.
    c = a64_word(c, 0xf100e2df); // cmp x22, #56
    let skip_clone = len(c.bytes);
    c = a64_word(c, 0x54000001);
    c = a64_word(c, 0xd1040031); // sub x17, x1, #256
    for i in 1..16 {
        c = a64_word(c, 0xf94003f0 | (i << 10));
        c = a64_word(c, 0xf9000230 | (i << 10));
    };
    c = a64_mov(c, 1, 17);
    c = a64_mov(c, 3, 4);
    c = a64_mov(c, 4, 10);
    c = a64_end(c, skip_clone);
    // The thread runtime unmaps its own stack immediately before exit.
    // Complete those two operations without reading that stack again.
    c = a64_word(c, 0xf1002edf); // cmp x22, #11
    c = a64_word(c, 0x54000161); // skip terminal path
    c = a64_word(c, 0xeb07039f); // cmp x28, x7
    c = a64_word(c, 0x54000123); // b.lo skip
    c = a64_word(c, 0x8b0600f0); // add x16, x7, x6
    c = a64_word(c, 0xeb10039f); // cmp x28, x16
    c = a64_word(c, 0x540000c2); // b.hs skip
    c = a64_word(c, 0xd4000001);
    c = a64_imm(c, 0, 0);
    c = a64_imm(c, 8, 93);
    c = a64_word(c, 0xd4000001);
    c = a64_word(c, 0xd4200000);
    c = a64_word(c, 0xd4000001); // svc #0
    c = a64_word(c, 0xf100e2df); // cmp x22, #56
    c = a64_word(c, 0x54000061);
    c = a64_word(c, 0xb5000040); // parent skips child SP update
    c = a64_word(c, 0x910403fc); // add x28, sp, #256
    c = a64_word(c, 0xf1041adf); // cmp x22, #262
    c = a64_word(c, 0x540000a1); // b.ne .+20
    c = a64_word(c, 0xb5000080); // cbnz x0, .+16
    c = a64_word(c, 0xf9400bf0); // ldr x16, [sp, #16] (stat buffer)
    c = a64_word(c, 0xb9401211); // ldr w17, [x16, #16]
    c = a64_word(c, 0xf9000e11); // str x17, [x16, #24]
    for i in 1..16 { c = a64_word(c, 0xf94003e0 | (i << 10) | i); };
    c = a64_word(c, 0xd51b4213); // msr nzcv, x19
    a64_word(c, 0xd65f03c0)
};
export { set_signals, A64Code, a64_encode, a64_new, a64_word, a64_imm };
