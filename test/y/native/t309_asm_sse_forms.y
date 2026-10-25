// The encoder's SSE forms, checked by running them rather than by reading the
// bytes. GNU as accepts the packed spelling of every one of these as an alias
// -- `movsd` without its F2 is `movups`, `mulsd` without it is `mulps` -- and the
// packed form still computes a plausible float, just the wrong one, so
// `make asm-check` cannot be the gate. src/y/arch/math.s's two probes exist only
// for this fixture; the shaker drops them from any binary that does not call
// them.
ndef sse_forms(a: float, b: float) -> float = "y_sse_forms";
ndef sse_flags(a: float, b: float) -> long = "y_sse_flags";

// (a*b)*2.0 + 0.5 - 0.25, all over 4.0, with the last three steps applied to
// what came back through a stack slot. Every step is exact in binary floating
// point, so the answer is arithmetic rather than a table: 3*5 = 15, *2 = 30,
// +0.5 = 30.5, -0.25 = 30.25, /4 = 7.5625.
print(f"{sse_forms(3.0, 5.0):.17f}");
print(f"{sse_forms(5.0, 3.0):.17f}");
print(f"{sse_forms(1.0, 1.0):.17f}");       // 2 + 0.5 - 0.25 = 2.25, /4 = 0.5625
print(f"{sse_forms(0.0, 0.0):.17f}");       // 0 + 0.5 - 0.25 = 0.25, /4 = 0.0625
print(f"{sse_forms(0.5, 0.25):.17f}");      // 0.125*2 = 0.25, +0.5 = 0.75,
//                                           // -0.25 = 0.5, /4 = 0.125
// the same arithmetic done in Y, so the fixture says which side moved if the
// two ever differ
def forms_y(a: float, b: float) -> float {
    let v = a * b * 2.0 + 0.5 - 0.25;
    v / 4.0
};
print(f"{forms_y(3.0, 5.0):.17f}");
print(f"{forms_y(0.5, 0.25):.17f}");
// a subnormal and an infinity still go through the same arithmetic
print(f"{sse_forms(1.0 / 0.0, 2.0):.17f}");
print(f"{sse_forms(5.0e-324, 2.0):.17f}"); // 2e-323 + 0.5 - 0.25 = 0.5, /4 = 0.125
                                          // -- a subnormal that no longer fits
print(f"{sse_forms(0.0 / 0.0, 2.0):.17f}"); // NaN in, NaN out

// The flags probe. ucomisd's SOURCE is compared against its destination, so
// sse_flags(a, b) answers "is b above a?". Bit 0 is unordered (an operand was
// a NaN), bit 1 the clear case, bit 2 strictly above, bit 3 above-or-equal
// (which includes unordered, because unordered sets CF), bit 4 below-or-equal
// (which also includes unordered). Bit 3 and bit 4 are never both clear: CF=0
// with ZF=0 versus CF=1 or ZF=1 covers every outcome there is.
def show(a: float, b: float) -> void {
    let f = sse_flags(a, b);
    print(f"{f} {(f & 1) == 1} {(f & 2) == 2} {(f & 4) == 4} {(f & 8) == 8} {(f & 16) == 16}");
};
show(1.0, 2.0);       // 2 > 1:      ordered, above
show(2.0, 1.0);       // 1 < 2:      ordered, below
show(1.0, 1.0);       // equal
show(0.0 / 0.0, 1.0); // NaN below
show(1.0, 0.0 / 0.0); // NaN above
show(0.0 / 0.0, 0.0 / 0.0); // both NaN
show(1.0 / 0.0, 1.0); // +inf below +inf: equal
show(1.0 / 0.0, 2.0); // finite above +inf: below
show(0.0, 0.0);       // +0 == +0
show(0.0, 0.0 - 0.0); // +0 above -0: equal, though the bits differ
show(5.0e-324, 0.0);  // the least subnormal above +0
show(-1.0, -2.0);     // negatives, -2 below -1