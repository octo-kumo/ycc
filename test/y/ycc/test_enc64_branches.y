// The two branch forms (E1), and the fixup each one carries.
//
// A branch whose target is within rel8 of it is two bytes instead of five or
// six: `EB rel8` against `E9 rel32` for jmp, `70+cc rel8` against
// `0F 80+cc rel32` for a conditional. Which form an instruction gets is not
// the encoder's decision -- an instruction's length has to be settled before
// the addresses are -- so `enc_insn` takes it as a parameter, and the
// assembler asks for short everywhere and grows what does not reach
// (asm.y's asm_relax). These are the bytes each form is, checked one at a
// time, plus the fixup offset: the field starts after the opcode, and after
// the two-byte `0F` prefix for the long conditional.
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

// A code label, the operand form a branch takes (enc64.y's Operand: every
// field, since a record type is its own set of fields).
def lbl(name: str) -> Operand {
    { k: K.lbl, n: 0, size: 0, v: 0, a: "", b: "", name: name, base: -1, idx: -1,
      scale: 1, disp: 0, rip: false, lbl: "" }
};

def check(what: str, got: str, want: str) {
    if (got != want) {
        print("MISMATCH: " + what);
        print("  got:  " + got);
        print("  want: " + want);
        exit(1);
    };
};

// enc(mnemonic, operand, long?) -> {bytes, at, fix} for one branch.
def enc(mn: str, o: Operand, lng: bool) -> { hex: str, at: long, kind: str, off: long, lbl: str, br: long } {
    let buf = enc64.scratch();
    let e = enc64.enc_insn(buf, 0, mn, [o], lng);
    if (e.err != "") {
        { hex: "ERR " + e.err, at: 0, kind: "", off: 0, lbl: "", br: -1 }
    } else {
        let f = e.fix[0];
        { hex: hex_of(buf[0:e.at]), at: e.at, kind: f.kind, off: f.off, lbl: f.lbl, br: e.br }
    }
};

// jmp: EB rel8 / E9 rel32. Both put the displacement at offset 1.
let s = enc("jmp", lbl("yL_a"), false);
check("jmp, short", s.hex, "eb 00");
check("jmp, short, length", tostring(s.at), "2");
check("jmp, short, fixup kind", s.kind, "rel8");
check("jmp, short, fixup offset", tostring(s.off), "1");
check("jmp, short, fixup label", s.lbl, "yL_a");
check("jmp, short, br", tostring(s.br), "0");

let l = enc("jmp", lbl("yL_a"), true);
check("jmp, long", l.hex, "e9 00 00 00 00");
check("jmp, long, length", tostring(l.at), "5");
check("jmp, long, fixup kind", l.kind, "rel32");
check("jmp, long, fixup offset", tostring(l.off), "1");

// A conditional: the short opcode is the long one's 16 bytes lower
// (0x84 -> 0x74 for je), and the long form's displacement starts after the
// two-byte 0F prefix.
let js = enc("je", lbl("yL_b"), false);
check("je, short", js.hex, "74 00");
check("je, short, fixup kind", js.kind, "rel8");
check("je, short, fixup offset", tostring(js.off), "1");
check("je, short, br", tostring(js.br), "132");

let jl = enc("je", lbl("yL_b"), true);
check("je, long", jl.hex, "0f 84 00 00 00 00");
check("je, long, length", tostring(jl.at), "6");
check("je, long, fixup kind", jl.kind, "rel32");
check("je, long, fixup offset (after the 0F prefix)", tostring(jl.off), "2");

let jn = enc("jne", lbl("yL_b"), false);
check("jne, short", jn.hex, "75 00");
check("jne, short, br", tostring(jn.br), "133");

// jg is 0x8f long / 0x7f short, js is 0x98 / 0x78: the same 16.
check("jg, short", enc("jg", lbl("yL_c"), false).hex, "7f 00");
check("js, short", enc("js", lbl("yL_c"), false).hex, "78 00");

// A call is never relaxed: E8 rel32, one form only. (`call *%reg` is a
// different operand kind and not a branch at all.)
let cl = { k: K.ind, n: 3, size: 64, v: 0, a: "", b: "", name: "", base: -1, idx: -1,
           scale: 1, disp: 0, rip: false, lbl: "" };
let cb = enc64.scratch();
let ce = enc64.enc_insn(cb, 0, "call", [cl], false);
check("call *%rbx is not a branch", hex_of(cb[0:ce.at]), "ff d3");
check("call *%rbx reports br = -1", tostring(ce.br), "-1");

// asm_relax re-encodes a grower through enc_branch_long, which is what the
// two forms have to agree on: the long form of the same branch, from the
// label name alone.
let rb = enc64.scratch();
let re = enc64.enc_branch_long(rb, 0, 0, "yL_d");
check("enc_branch_long of a jmp", hex_of(rb[0:re.at]), "e9 00 00 00 00");
check("enc_branch_long of a jmp, fixup", re.fix[0].kind, "rel32");
let rb2 = enc64.scratch();
let re2 = enc64.enc_branch_long(rb2, 0, 133, "yL_e");
check("enc_branch_long of a jne", hex_of(rb2[0:re2.at]), "0f 85 00 00 00 00");
check("enc_branch_long of a jne, fixup offset", tostring(re2.fix[0].off), "2");

// A label operand is not a valid target for the forms that take no label:
// still a loud error, never a silent encoding of something else.
check("jmp with a register operand", enc("jmp", { k: K.reg, n: 0, size: 64, v: 0, a: "", b: "",
      name: "", base: -1, idx: -1, scale: 1, disp: 0, rip: false, lbl: "" }, false).hex,
      "ERR jmp target");

print("enc64: both branch forms encode as GNU as does");