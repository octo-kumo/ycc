// rnd.y -- a seeded pseudo-random generator, and nothing else.
//
// WHY A FILE FOR THIS.  Y has no `rand`, no `random`, no `srandom` and no
// seed builtin (there is no randomness at all in the language -- the only
// entropy in the tree is syscall 318, `getrandom`, which a deterministic
// example must never reach).  A roguelike needs thousands of numbers per
// level, so it needs a generator, and it needs the same one every run.
//
// THE GENERATOR.  `x <- x * M + C (mod 2^63)`, the 64-bit LCG from Numerical
// Recipes / PCG: M = 6364136223846793005, C = 1442695040888963407.  Both fit
// in a signed 64-bit `long`, and Y's `long` multiply and add WRAP rather than
// trapping or saturating -- `4611686018427387904 * 4` is 0, and
// `9223372036854775807 + 1` is -2^63 -- so the modulus is free.  Nothing here
// allocates and nothing here keeps a table, so a call from the hottest loop in
// a program is free.
//
// The value handed to a caller is the TOP 31 bits, `(x >>> 33)`, which is the
// part of an LCG state that is actually well mixed: the low bits of an LCG
// have short periods.  `>>> 1` would also be non-negative, but 33 gives a
// positive result for every possible state, which keeps `below()` free of a
// sign fix-up.
//
// NO STATE YOU CAN SEE, ONLY THE ONE YOU SET.  `seed(v)` runs the argument
// through three rounds of a murmur-style finaliser, so `--seed 1` and
// `--seed 2` give unrelated streams (an un-finalised LCG started from 1 and 2
// would interleave visibly), and a zero state is replaced rather than
// accepted: an LCG with state 0 is stuck at 0 forever.

let RS: long = 88172645463325252;     // "the state is never all zeroes"

const MUL: long = 6364136223846793005;
const ADD: long = 1442695040888963407;

// seed(v) -- start the stream from `v`.  The finaliser is xorshift-multiply
// twice, which is enough to make neighbouring seeds look unrelated; a zero
// result is replaced, because 0 is the LCG's fixed point.
def seed(v: long) {
    let s = v;
    s = (s ^ (s >>> 33)) * MUL;
    s = s ^ (s >>> 33);
    s = s * MUL;
    s = s ^ (s >>> 33);
    RS = if (s == 0) { 88172645463325252 } else { s };
};

// next() -> long -- the whole 64-bit state, for a caller that wants it.
def next() -> long {
    RS = RS * MUL + ADD;
    RS
};

// below(n) -> long -- a uniform value in 0..n-1.  n <= 0 gives 0 rather than
// trapping on a division by zero: every caller here passes a count it has
// already clamped, and a trap would land on stdout and corrupt a frame
// (ORCHESTRATOR.md 2.6).
def below(n: long) -> long {
    if (n <= 0) { return 0; };
    (next() >>> 33) % n
};

// range(lo, hi) -> long -- a uniform value in lo..hi INCLUSIVE.  hi < lo gives
// lo, so a caller that asks for an empty range gets a defined answer instead
// of a negative modulus.
def range(lo: long, hi: long) -> long {
    if (hi <= lo) { return lo; };
    lo + below(hi - lo + 1)
};

// chance(pct) -> bool -- true with probability pct/100.
def chance(pct: long) -> bool {
    below(100) < pct
};

export { seed, next, below, range, chance };
