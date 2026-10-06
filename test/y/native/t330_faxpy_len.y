// faxpy with arrays of different lengths -- the same helper as t329, reached
// from the other of the two functions that uses it, and pinned separately
// because the runtime error stops the program: one fixture can only ever print
// the first message, so a single fixture covering both would leave faxpy's
// untested while looking as though it were covered.
//
// The check is on the two arrays' lengths, not on the result: faxpy writes in
// place into its first argument, so a mismatch means the write would run off the
// end of one of them. That is why it stops rather than truncating.

import math;

let dst: [float] = [1.0, 2.0];
let src: [float] = [1.0];

math.faxpy(dst, 2.0, src);
