// fdot with arrays of different lengths, and faxpy with the same problem.
//
// Both go through len_mismatch, and NEITHER had a case until now: the helper
// prints a runtime error and stops, so the path exists and nothing asked it. It
// is the one diagnostic in this module with no gate, found by asking which
// exported names appear in neither the ulp table nor a fixture and then checking
// each of the 23 against what reaches it. Most turned out to be oracles or
// helpers reached transitively -- pow_y, pow_int and pow_pos serve pow_asm,
// which t315 pins against them -- but these two are on a runtime path a program
// takes by passing the wrong arrays, and a wrong-length fdot is a plausible
// mistake rather than a contrived one.
//
// The message names the CALLER, not the helper. That is the part worth pinning:
// `fdot needs two arrays of the same length` says which of the two functions
// was asked, so a program reading the message knows which call to fix. One
// fixture per function, because the runtime error stops the program and only
// the first of them would ever be printed.

import math;

let two: [float] = [1.0, 2.0];
let one: [float] = [1.0];

print(math.fdot(two, one));
