// rng.y -- the seeded generator every maze in this folder is built from.
//
// WHY HAND-ROLLED.  The deterministic run has to be byte-identical every time
// and on every machine, and Y has no `random` unit and no `srand`: a stream
// from the C library would be one more thing that can change under the fixed
// output.  A named algorithm with a named seed is the only version of "random"
// that can be promised to reproduce.
//
// The algorithm is splitmix64 (Steele, Lea & Flood, 2014): three
// xor-shift-multiply rounds on a counter.  It is fast, has no state beyond one
// long, and is the one whose constants are written down, so this file is the
// algorithm -- not a comment describing one.
//
// REJECTION, NOT `%`.  `x % n` is biased for every n that is not a power of
// two, because 2^62 does not divide by n, and the low indices then come up
// more often than the high ones.  A maze generator's entire character comes
// out of this one draw, so the bias would be the example's bias.  rng_below
// therefore takes the low 62 bits and throws away the values below the largest
// whole multiple of n, which makes the distribution exactly uniform.
//
// ─────────────────────────────────────────────────────────────────────────
// NO `break` HERE EITHER.  The rejection loop's exit IS its condition: it
// spins until the draw lands in the accepted range.  That is the whole
// difference between this and a C version -- there is nothing to break out of,
// because "a good draw" and "keep going" are the same test.

// splitmix64's three constants.  They are the reference values, and the tree
// has no 64-bit literal suffix, so they are spelled in hex: a hex literal
// wider than 2^63 wraps into the negative half of the long, which is exactly
// the two's-complement bit pattern the algorithm wants.
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
def rng_seed(v: long) -> void {
    st = v + GOLDEN
};

// rng_next() -> long -- the next 64 bits of the stream.
//
// The shifts are `>>>` (logical), not `>>` (arithmetic): the reference
// algorithm shifts the bit pattern right, and with a signed long an arithmetic
// shift would carry the sign bit down and produce a different (weaker) mixer.
// Spelling them out here is the difference between "splitmix64" and "something
// that is not".
def rng_next() -> long {
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
def rng_below(n: long) -> long {
    if (n < 1) { return 0; };
    let span = TOP62 + 1;                   // 2^62 draws
    let lim = (span / n) * n;               // the largest whole multiple of n in [0, span)
    let v = 0 - 1;                          // the sentinel: forces one draw
    // `v < 0` is what forces the first draw -- and it has to be spelled out,
    // because `%` in Y is C's truncated remainder, so `-1 % n` is -1 and NOT
    // the last index.  A sentinel that leans on the modulus being non-negative
    // would hand the caller -1 from inside what looks like a generator.
    while (v < 0 || v >= lim) { v = rng_next() & TOP62; };
    v % n
};

export { rng_seed, rng_next, rng_below };