// tolong's one runtime error: a float with no long answer.
//
// The bound is exact in both directions and both ends are pinned here, because
// a half-checked bound is the worst of the three: it either rejects values
// that had an answer or admits values that had none, and a fixture that only
// tests one side cannot tell which happened. This one only reaches the first
// failure -- the trap exits -- so the cases are in e319 instead, where each is
// run in its own process and all four answers are checked.
//
//    -2^63  IS a long (the most negative one), and comes back as itself.
//     2^63  is not. The machine cast alone would answer with its "integer
//           indefinite" value, 0x8000000000000000: a legal long and a wholly
//           misleading one. It would index an array, and the fault would be
//           far from its cause.
//     a NaN is out of range too, and no comparison catches it, so the
//           self-inequality test has to.
//
// Here: the bound from below, which must NOT trap, and the float above the
// bound, which must. Two directions, one process, exit 1.

print(tolong(-9223372036854775808.0)!);
print(tolong(9.3e18)!);