// The encoder's memory-destination ALU and unary forms (B1).
//
// `enc_alu_imm` and `enc_unary` used to reject any operand that is not a
// register, so `add $1, -8(%rbp)` and `inc -8(%rbp)` -- one instruction each,
// where the emitter had to load the slot into a register, add, and store it
// back -- were not expressible. These are the bytes they encode to, checked
// one at a time.
//
// Every expected sequence is what GNU as produces for the same instruction
// spelled with an explicit `q` suffix (`as` guesses 32-bit for a sizeless
// memory operand, and a Y long is 64-bit, so the suffix is the comparison).
// A memory operand carries no size in our own assembler either, so these
// forms are the 64-bit ones for the same reason.
//
// The rip-relative case is here for the fixup offset as much as for the
// encoding: x86 orders a form ModRM, SIB, displacement, immediate, so the
// disp32 field sits BETWEEN the ModRM and the immediate. It used to be
// appended last, which put it after the immediate -- an instruction that
// encodes cleanly, links cleanly, and addresses the wrong four bytes.
import enc64 from "../../../src/y/enc64.y";
import tags from "../../../src/y/tags.y";

def hex2(v: long) -> str {
    let digits = "0123456789abcdef";
    digits[v / 16 : v / 16 + 1] + digits[v % 16 : v % 16 + 1]
};

def hex_of(b: [byte]) -> str {
    let out: [str] = [];
    let i = 0;
    while (i < len(b)) {
        out += hex2(b[i]);
        i = i + 1;
    };
    join(out, " ")
};

// A memory operand: every field of the record, since a record type is its own
// set of fields (enc64.y's Operand).
def mem(base: long, idx: long, scale: long, disp: long) -> Operand {
    { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: base, idx: idx,
      scale: scale, disp: disp, rip: false, lbl: "" }
};
def rip_mem(lbl: str) -> Operand {
    { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: -1, idx: -1,
      scale: 1, disp: 0, rip: true, lbl: lbl }
};
def imm(v: long) -> Operand {
    { k: K.imm, n: 0, size: 0, v: v, a: "", b: "", name: "", base: -1, idx: -1,
      scale: 1, disp: 0, rip: false, lbl: "" }
};
def reg(n: long) -> Operand {
    { k: K.reg, n: n, size: 64, v: 0, a: "", b: "", name: "", base: -1, idx: -1,
      scale: 1, disp: 0, rip: false, lbl: "" }
};

// `mnemonic, operand...` is the assembler's own order (source order).
def enc(mn: str, ops: [Operand]) -> str {
    let e = enc64.enc_insn(mn, ops);
    if (e.err != "") { "ERR " + e.err } else { hex_of(e.bytes) }
};

def check(what: str, got: str, want: str) {
    if (got != want) {
        print("MISMATCH: " + what);
        print("  got:  " + got);
        print("  want: " + want);
        exit(1);
    };
};

// base rbp with a disp8, the frame-slot shape the emitter's fast paths use.
let rbp8 = mem(5, -1, 1, -8);
let rbp4 = mem(5, -1, 1, -4);
let rsp16 = mem(4, -1, 1, 16);
let rax0 = mem(0, -1, 1, 0);
let r12_0 = mem(12, -1, 1, 0);
let r13_m4 = mem(13, -1, 1, -4);
let rax_big = mem(0, -1, 1, 1048575);
let sib = mem(0, 1, 4, 8);
let rax_4k = mem(0, -1, 1, 4096);

// The ALU group with an immediate: 83 /ext ib when the immediate fits in a
// signed byte, 81 /ext id when it does not.
check("add $1, -8(%rbp)", enc("add", [imm(1), rbp8]), "48 83 45 f8 01");
check("add $1000, -8(%rbp)", enc("add", [imm(1000), rbp8]), "48 81 45 f8 e8 03 00 00");
check("sub $1, 16(%rsp)", enc("sub", [imm(1), rsp16]), "48 83 6c 24 10 01");
check("cmp $5, -8(%rbp)", enc("cmp", [imm(5), rbp8]), "48 83 7d f8 05");
check("and $255, (%rax)", enc("and", [imm(255), rax0]), "48 81 20 ff 00 00 00");
check("or $1, (%r12)", enc("or", [imm(1), r12_0]), "49 83 0c 24 01");
check("xor $2, -8(%rbp)", enc("xor", [imm(2), rbp8]), "48 83 75 f8 02");
check("cmp $-1, -8(%rbp)", enc("cmp", [imm(-1), rbp8]), "48 83 7d f8 ff");
check("add $1, -4(%r13)", enc("add", [imm(1), r13_m4]), "49 83 45 fc 01");
check("add $1, 8(%rax,%rcx,4)", enc("add", [imm(1), sib]), "48 83 44 88 08 01");
check("add $1, 1048575(%rax)", enc("add", [imm(1), rax_big]),
      "48 83 80 ff ff 0f 00 01");
check("cmp $1, -8(%rbp) is still the 32-bit register path's imm8",
      enc("cmp", [imm(1), reg(1)]), "48 83 f9 01");

// inc/dec/not r/m64: FF /0, FF /1, F7 /2 -- the same /ext the register form
// uses, with a ModRM that is not mod=11.
check("inc -8(%rbp)", enc("inc", [rbp8]), "48 ff 45 f8");
check("dec -8(%rbp)", enc("dec", [rbp8]), "48 ff 4d f8");
check("not -8(%rbp)", enc("not", [rbp8]), "48 f7 55 f8");
check("inc (%r12)", enc("inc", [r12_0]), "49 ff 04 24");
check("inc 4096(%rax)", enc("inc", [rax_4k]), "48 ff 80 00 10 00 00");
check("dec %r13", enc("dec", [reg(13)]), "49 ff cd");   // REX.B, rm = 101

// The rip-relative form: REX 83 modrm(00,000,101) then a disp32 the linker
// fills in, then the immediate. So the disp32 field starts at offset 3 --
// after the ModRM, before the immediate -- and that is where the fixup must
// point. It used to point at 4, the byte *after* the field, which is the
// immediate: the patch landed one byte late and the instruction addressed the
// wrong four bytes while still assembling and linking cleanly.
let rip = enc64.enc_insn("add", [imm(1), rip_mem("yref")]);
check("add $1, yref(%rip)", hex_of(rip.bytes), "48 83 05 00 00 00 00 01");
if (len(rip.fix) != 1) {
    print("MISMATCH: add $1, yref(%rip) wants one fixup, got " + tostring(len(rip.fix)));
    exit(1);
};
let f = rip.fix[0];
check("the rip fixup's offset", tostring(f.off), "3");
check("the rip fixup's kind", f.kind, "rip32");
check("the rip fixup's label", f.lbl, "yref");

// What did NOT become expressible. The one-operand division group has no
// memory form (F7 with ModRM mod=11 only), and an immediate with no opcode
// for it is still a loud error rather than a silent encoding of something
// else.
check("idiv -8(%rbp)", enc("idiv", [rbp8]), "ERR unary form");
check("div -8(%rbp)", enc("div", [rbp8]), "ERR unary form");
check("imul $1, -8(%rbp) (a register-only two-operand form)",
      enc("imul", [imm(1), rbp8]), "ERR imul form");

// An immediate outside int32 is the door the register form already had: 81
// /ext id takes a sign-extended imm32 and nothing else.
check("add 4294967366, -8(%rbp)", enc("add", [imm(4294967366), rbp8]),
      "ERR an immediate does not fit in 32 bits");

print("enc64: the memory-destination ALU and unary forms encode as GNU as does");