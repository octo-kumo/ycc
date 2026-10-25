// The float-to-decimal rules, at the places where they decide something.
//
// The manual documents two of them -- "a field without a spec is tostring, so a
// float shows six decimals", and "float prints as Python prints it" for the spec
// forms -- and t69_fstrings pinned them at 2.5 and at 1e300. Both of those are
// places where the rules are uninteresting. Nothing asked what six decimals does
// where it stops carrying information, nothing asked which side of its own
// rounding seam a value falls, and nothing asked what a NEGATIVE ZERO prints as.
//
// That is the same shape as every other gap this work has closed: a gate that
// reads as coverage and is not, because it pins a rule's comfortable middle.
//
// WHAT IS PINNED HERE, and why each is a decision rather than a fact:
//
//  1. THE SEAM of the six-decimal rule, bisected rather than assumed. 0.0000005 is
//     the smallest magnitude that can round UP to 0.000001, and which side a
//     value exactly on it falls is a rounding decision -- half-to-even gives
//     0.000000, half-away gives 0.000001. Bisecting against Python's "%.6f", the
//     reference the manual's "prints as Python prints it" rests on, puts the
//     last 0.000000 at 4.9999999999999998e-07 and the first 0.000001 at
//     5.0000000000000008e-07. So 5e-7 ITSELF is below the seam and the seam is
//     one representable step above it -- which is not where a reader would put
//     it, and is the reason to write the value down rather than say "5e-7".
//
//  2. THE DEGENERATION. Every float under 5e-7 prints as 0.000000, including the
//     least subnormal and 1e-300. That is what six decimals means, so it is not a
//     defect -- but it is a place a program can lose a value without noticing,
//     and it was nowhere.
//
//  3. HALF ROUNDING at .0f, which is a different answer from half-to-even: printf
//     rounds half AWAY FROM ZERO, so 3.5 is 4 and -2.5 is -2. Y agrees, and 0.5
//     is 0 and -0.5 is -0 -- the last of those is a rounding decision visible in
//     the text, since "-0" and "0" are different answers to "what is this".
//
//  4. THE SIGN OF ZERO, in every form. -0.0 is not a literal in Y (0.0 - 0.0 is
//     +0.0 by IEEE round-to-nearest, which is a trap this file fell into while
//     being written and which is why the zero below is built by multiplying), and
//     it has to survive into the text: -0.000000, -0.0, -0, -0.000000e+00. This
//     module has got the sign of a zero wrong three times already -- fmin/fmax's
//     tie, expm1(-0.0), atan2(-0, +0) -- so it is checked here rather than
//     assumed, and a formatting change that dropped the sign would be caught.
//
//  5. THE EQUIVALENCE the manual's sentence rests on: a field with no spec is
//     tostring, so f"{x}" and tostring(x) are the same text. That is the one thing
//     a change to either code path could break without moving a number above.
//
// The reference throughout is Python's printf, because that is what "prints as
// Python prints it" claims. Every value here was checked against it and agrees.

import math;

def show(label: str, v: float) -> void {
    let t = tostring(v);
    print(label + " " + t + "  (" + tostring(t.length) + " chars)");
};

print("── the six-decimal seam: 5e-7 is BELOW it, one step up is above ──");
show("4.9999999999999998e-07 ", 4.9999999999999998e-07);
show("5e-07                   ", 5e-07);
show("5.0000000000000008e-07  ", 5.0000000000000008e-07);
show("5.0000000000000019e-07  ", 5.0000000000000019e-07);
show("-4.9999999999999998e-07 ", 0.0 - 4.9999999999999998e-07);
show("-5e-07                  ", 0.0 - 5e-07);
show("-5.0000000000000008e-07 ", 0.0 - 5.0000000000000008e-07);

print("── the rule degenerates: every float under 5e-7 is 0.000000 ──");
show("1e-07                   ", 1e-07);
show("1e-08                   ", 1e-08);
show("1e-300                  ", 1e-300);
show("5e-324 least subnormal  ", 5e-324);
show("2.2250738585072014e-308  ", 2.2250738585072014e-308);
show("-1e-300                  ", 0.0 - 1e-300);

print("── and at the top it stops being a decimal ──");
show("1e15                    ", 1e15);
show("1e16                    ", 1e16);
show("1e22                    ", 1e22);
show("12345678901234567890.0  ", 12345678901234567890.0);
show("1.7976931348623157e308  ", 1.7976931348623157e308);

print("── half rounding at .0f is half AWAY FROM ZERO, not to even ──");
let halves: [float] = [0.5, 1.5, 2.5, 3.5, 0.05, 0.15, 0.25, 2.4999999999999996,
                       0.0 - 0.5, 0.0 - 2.5, 0.0 - 3.5];
let i = 0;
while (i < len(halves)) {
    let v = halves[i];
    print("  " + f"{v:.6f}" + "  ->  .0f " + f"{v:.0f}" + "   .1f " + f"{v:.1f}"
        + "   .2f " + f"{v:.2f}");
    i = i + 1
};

print("── the sign of a zero survives into the text ──");
// -0.0, which no literal spells: 0.0 - 0.0 is +0.0 by IEEE, so it is built by
// multiplying. Getting this wrong is how the line above was wrong first.
let nz: float = 0.0 * (0.0 - 1.0);
print("  bits                 " + tostring(math.fbits(nz)));
print("  tostring             " + tostring(nz));
print("  f\"{nz}\"                " + f"{nz}");
print("  f\"{nz:.6f}\"            " + f"{nz:.6f}");
print("  f\"{nz:.1f}\"            " + f"{nz:.1f}");
print("  f\"{nz:.0f}\"            " + f"{nz:.0f}");
print("  f\"{nz:e}\"              " + f"{nz:e}");
print("  and +0.0 for contrast " + tostring(0.0) + "  " + f"{0.0:.0f}");
print("  f\"{nz}\" == tostring(nz)   " + (f"{nz}" == tostring(nz)));

print("── the manual's own examples ──");
print("  f\"{2.5}\"                 " + f"{2.5}");
print("  f\"{0.125:.2f}\"           " + f"{0.125:.2f}");
print("  f\"{0.1:.20f}\"            " + f"{0.1:.20f}");

print("── a field with no spec IS tostring ──");
let same = 0;
let vs: [float] = [0.0, 0.0 * (0.0 - 1.0), 1.0, 0.0 - 1.0, 2.5, 0.1, 1.0 / 3.0,
                   5e-324, 1e-300, 5e-07, 5.0000000000000008e-07, 1e16, 1e22,
                   1e300, 1.7976931348623157e308];
i = 0;
while (i < len(vs)) {
    let v = vs[i];
    if (f"{v}" == tostring(v)) {
        same = same + 1
    } else {
        print("  DIFFER at " + f"{v:.6f}" + ": " + f"{v}" + " vs " + tostring(v))
    };
    i = i + 1
};
print("  f\"{x}\" == tostring(x) on " + tostring(same) + " of " + tostring(len(vs)));
