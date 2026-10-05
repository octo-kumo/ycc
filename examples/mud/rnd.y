// rnd.y -- the ONE source of randomness in this program.
//
// ===========================================================================
// WHY A MODULE OF ITS OWN
// ===========================================================================
//
// The whole example is a pure function of --seed.  That is a contract, not a
// hope: two runs of `./mud --frames 9 --seed 1` must produce identical bytes,
// and the gate diffs them.  So there is no `getrandom`, no `clock_us`, no pid
// and no address anywhere in a value that reaches stdout.
//
// Combat needs randomness too, and combat happens inside a *session*, on a
// worker thread, concurrently with other sessions.  If every session shared
// one generator, two players fighting in the same room would interleave draws
// and each player's transcript would depend on the other's timing -- the
// golden file would be unreproducible.  So each session gets its OWN copy of
// the generator, seeded from (seed, session slot), and a session is served by
// exactly one worker for its whole life.  That is what makes concurrent play
// deterministic without a lock: see server.y, "WHY A SESSION OWNS ITS WORLD".
//
// ===========================================================================
// THE GENERATOR
// ===========================================================================
//
// 64-bit LCG, the numerical-recipes constants (a = 6364136223846793005,
// c = 1442695040888963407).  Chosen because the low bits of an LCG are bad
// and because `rnd(n)` below needs *uniformity in the high bits*, not in the
// low ones, so every call shifts down first.  Y has no unsigned arithmetic and
// no overflow trap, and the multiply wraps in a machine register, so the
// arithmetic below is exactly the C one's.

let st: [long] = [1];

def rnd_seed(seed: long) -> long {
    // a zero state would be a fixed point; nudge it.  Negative seeds are
    // allowed (they are a legitimate way to explore the generator) and are
    // folded here rather than at every draw.
    let s = seed;
    if (s == 0) { s = 1; };
    st[0] = s;
    0
};

// The raw 64-bit step.  Returns the new state.
def rnd_next() -> long {
    st[0] = st[0] * 6364136223846793005 + 1442695040888963407;
    st[0]
};

// Uniform-ish integer in [0, n).  n must be > 0: the caller checks (there is
// no `% 0`, it would trap).  The high 32 bits are what are used, because the
// low bits of an LCG have very short periods.
def rnd_below(n: long) -> long {
    let hi = rnd_next();
    // hi >> 33 keeps 31 bits, which is above 2^31 and so above any n a MUD
    // world needs; the shift is arithmetic and hi may be negative, which is
    // fine: % on a negative long in Y is C's (truncated toward zero), so the
    // sign is removed first.
    let u = (hi >> 33) & 0x7fffffff;
    if (u < 0) { 0 } else { u % n }
};

def rnd_state() -> long { st[0] };
def rnd_set_state(v: long) -> long { st[0] = v; 0 };

export { rnd_seed, rnd_next, rnd_below, rnd_state, rnd_set_state };