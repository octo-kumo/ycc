// The encoder's `test $imm, %reg`, checked by running it rather than by reading
// the bytes. The form has two encodings that differ by one byte -- F7 /0 reads
// the register the instruction names, F6 /0 reads %al and ignores REX.W -- and
// both are legal x86, so `make asm-check` accepts either and a fixture on a
// small value cannot separate them: `test $1, %rax` answers exactly what
// `test $1, %al` answers for every index under 256. The probe in
// src/y/arch/math.s uses $257 for that reason, an immediate the 8-bit encoding
// cannot even hold.
//
// native def (P1) is what lets the fixture reach an assembly label at all, and
// the `y_` prefix keeps it out of the program's own namespace.
native def test_imm(n: long) -> long = "y_test_imm";

// The flags as the probe reports them: bit 0 ZF, bit 1 SF, bit 2 CF, bit 3 PF,
// bits 4 and up the AND of n with 257. Printed beside the arithmetic the reader
// can check by hand, because a wrong flag bit is otherwise invisible.
def show(n: long) -> void {
    let f = test_imm(n);
    let zf = f & 1;
    let sf = (f >> 1) & 1;
    let cf = (f >> 2) & 1;
    let pf = (f >> 3) & 1;
    let r = f >> 4;
    // CF is printed because it is always 0 and always being 0 is the point:
    // TEST is an AND and clears it, where CMP on the same operands would set it
    // (0 < 257), so the column says the instruction is the one that was meant.
    print(f"n={n:<8} and={r:<5} ZF={zf} SF={sf} CF={cf} PF={pf}   (n&257={n & 257}, n even={(1 - (n & 1))})");
};
// bit 8 of n set: the 64-bit form sees it, the 8-bit form cannot
show(256);
show(257);
show(512);
show(768);
// bit 8 clear, bit 0 set and clear
show(1);
show(2);
show(255);
show(511);
// nothing in common with 257
show(0);
show(64);
// a negative long: SF is the sign, and bit 8 of the two's complement is set
show(-1);
show(-256);
// wide enough that the low byte and the whole register differ in bit 8
show(65536);
show(65792);
