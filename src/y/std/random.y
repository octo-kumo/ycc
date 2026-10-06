// random -- a seeded, replayable pseudo-random generator.
//
// WHY THIS IS A std MODULE.  TODO.md item 4 already asks for it.  Three
// examples wrote one anyway (examples/maze/rng.y, examples/mud/rnd.y,
// examples/roguelike/rnd.y, 3 KB each) and no two of them agree on the names,
// which is the cheapest possible evidence that the interface is underspecified.
//
// The public surface is seven functions:
//
//   seed(v)          next()          below(n)
//   range(lo, hi)    chance(pct)     state()    set_state(v)
//
// splitmix64 (Steele, Lea & Flood, 2014).  Seeding from the kernel is
// deliberately NOT done here: std/crypto.y already reaches getrandom(2) at
// syscall(318, ...), and a program that wants an unseeded stream should say so
// by calling crypto, not by getting it by omission.

const GOLDEN: long = 0x9E3779B97F4A7C15;
const MIX1: long = 0xBF58476D1CE4E5B9;
const MIX2: long = 0x94D049BB133111EB;

// 2^62 - 1.  rng_below draws from [0, 2^62), which is 4.6e18 draws wide: the
// rejection probability for any n this example uses is below 1e-13.
const TOP62: long = 0x3FFFFFFFFFFFFFFF;

let st: long = 1;

// rng_seed(v) -> void -- restart the stream at v.
//
// The state is offset by the golden-ratio constant before the first draw.
// That is splitmix64's own advice and it matters here for a concrete reason:
// seed 0 is a legal value on this command line (`--seed=0`), and a stream
// seeded straight at 0 has visibly weaker early bits.
def seed(v: long) -> void {
    st = v + GOLDEN
};

// rng_next() -> long -- the next 64 bits of the stream.
//
// The shifts are `>>>` (logical), not `>>` (arithmetic): the reference
// algorithm shifts the bit pattern right, and with a signed long an arithmetic
// shift would carry the sign bit down and produce a different (weaker) mixer.
// Spelling them out here is the difference between "splitmix64" and "something
// that is not".
def next() -> long {
    st = st + GOLDEN;
    let z = st;
    z = (z ^ (z >>> 30)) * MIX1;
    z = (z ^ (z >>> 27)) * MIX2;
    z ^ (z >>> 31)
};

// rng_below(n) -> long -- a uniform integer in 0..n-1, for n >= 1.
//
// n < 1 answers 0 rather than trapping: a caller that divides by an empty
// frontier has already lost, and the generators here size their frontiers
// from the grid so it cannot happen -- but the arithmetic below is shared, and
// `n % n` on a zero n is a division by zero trap (ORCHESTRATOR.md 2.6 traps on
// stdout, which would land in the middle of a frame).
//
// A bound of exactly 2^62 is the LARGEST this can serve, and the reason is a
// property of the loop rather than of the stream: it draws from [0, 2^62) and
// rejects anything at or above the largest whole multiple of n in that range.
// One past 2^62 there is no whole multiple at all -- (span / n) is 0, so lim is
// 0 -- and then EVERY draw is at or above lim and the loop never ends.
// `below(4611686018427387905)` hung the program outright, which is the worst
// answer a generator can give and the one no caller can recover from. A bound
// past the span is a caller asking for more entropy than the stream has
// granularity for, so it answers 0, by the same rule as n < 1.
//
// That leaves 2^62 exactly, which works because lim == span and the accept test
// `v >= lim` is then false for every v the mask can produce.
def below(n: long) -> long {
    let span = TOP62 + 1;                   // 2^62 draws
    if (n < 1 || n > span) { return 0; };
    let lim = (span / n) * n;               // the largest whole multiple of n in [0, span)
    let v = 0 - 1;                          // the sentinel: forces one draw
    // `v < 0` is what forces the first draw -- and it has to be spelled out,
    // because `%` in Y is C's truncated remainder, so `-1 % n` is -1 and NOT
    // the last index.  A sentinel that leans on the modulus being non-negative
    // would hand the caller -1 from inside what looks like a generator.
    while (v < 0 || v >= lim) { v = next() & TOP62; };
    v % n
};

// range(lo, hi) -> long -- a uniform integer in lo..hi inclusive.
//
// The width is hi - lo + 1, which OVERFLOWS for a range spanning most of the
// word: range(LONG_MIN, LONG_MAX) has a true width of 2^64, and the arithmetic
// wraps to 0, so below(0) answers 0 and the draw is always lo. It used to hang
// instead, because the wrapped 0 was below(0) before the bound was clamped and
// a width of exactly 2^62 one below LONG_MIN wrapped to -1 -- which reaches
// below's n < 1 arm by a different route. So the width is computed so it cannot
// wrap, and a span too wide to draw from answers lo, which is one of the values
// in the range and therefore an answer this function may give.
def range(lo: long, hi: long) -> long {
    if (hi < lo) { return lo };
    // (hi - lo) + 1 without the wrap: if hi - lo is LONG_MAX the +1 would be
    // 2^63, which is not a long. LONG_MIN / 2 is the other bound -- lo + the
    // width must not wrap either -- so both ends are checked.
    let w = hi - lo;
    if (w == 9223372036854775807 || w < 0 - 9223372036854775807 - 1 + 1) { return lo };
    let n = w + 1;
    if (n < 1 || n > 4611686018427387904) { return lo };
    lo + below(n)
};

// chance(pct) -> bool -- true with probability pct/100.
def chance(pct: long) -> bool {
    if (pct <= 0) { return false };
    if (pct >= 100) { return true };
    below(100) < pct
};

// state() -> long -- the generator's whole state.
//
// This is the one function TODO.md 4's sketch does not have, and the reason it
// is here: that entry says "a failing case is worthless if it cannot be
// replayed", and then can only seed from the START of a stream.  examples/mud
// grew rnd_state/rnd_set_state because a MUD bug reproduces from the exact
// point of divergence, not from tick 0 of a 3000-tick session.  One long.
def state() -> long { st };

def set_state(v: long) -> void { st = v };

export { seed, next, below, range, chance, state, set_state };