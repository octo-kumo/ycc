// std/random: splitmix64, the seeded stream, the bounded draws, and the state
// handle that makes a second independent stream possible.
//
// The determinism checks here are the point: a generator whose output depends on
// anything but its seed is unusable in a test, so each one re-seeds and draws
// twice and compares.
import random;
import test;

def main() -> long {
    // ─────────────────────────────────────────── seeding and the raw stream
    test.group("the seeded stream");
    random.seed(1);
    let a1 = random.next();
    let a2 = random.next();
    test.ck("two draws from one seed differ", a1 != a2, "a stream, not a constant");
    random.seed(1);
    test.ck_eq("and the same seed gives the same first draw", random.next(), a1);
    test.ck_eq("and the same second", random.next(), a2);

    random.seed(2);
    test.ck("a different seed gives a different stream",
        random.next() != a1, "seed 2 against seed 1");

    // A seed of 0 is legal here (splitmix64 has no zero fixed point), which is
    // worth stating because an LCG does have one and callers have learned to
    // avoid 0.
    random.seed(0);
    let z1 = random.next();
    random.seed(0);
    test.ck_eq("seed 0 is not a fixed point", random.next(), z1);
    test.ck("and it still moves", random.next() != z1, "the second draw differs too");

    // a negative seed, which a caller reaches by folding a user-supplied value
    random.seed(0 - 5);
    let n1 = random.next();
    random.seed(0 - 5);
    test.ck_eq("a negative seed is accepted and reproducible", random.next(), n1);

    // ─────────────────────────────────────────── below(n): the bound
    test.group("below(n) stays inside its bound");
    // n below 1 answers 0 rather than trapping: a trap prints to stdout, which
    // in a frame loop lands in the middle of a frame.
    test.ck_eq("below(0) is 0, not a division by zero", random.below(0), 0);
    test.ck_eq("below(1) is 0", random.below(1), 0);
    test.ck_eq("below(-5) is 0", random.below(0 - 5), 0);
    // A bound past the 2^62 the loop draws from is the other end of the same
    // rule. It is here because it HUNG: (span / n) is 0 one past 2^62, so lim is
    // 0, so `v >= lim` rejects every draw and the loop never ends. The worst
    // answer a generator can give, and the one no caller can recover from.
    test.ck("below(2^62) is served -- it is the largest bound that is", {
        random.seed(42);
        let v = random.below(4611686018427387904);
        v >= 0 && v < 4611686018427387904
    }, "inside its own bound");
    test.ck_eq("below(2^62 + 1) answers 0 rather than hanging",
        {
            random.seed(42);
            random.below(4611686018427387905)
        }, 0);
    test.ck_eq("and below(LONG_MAX) too", {
        random.seed(42);
        random.below(9223372036854775807)
    }, 0);
    test.ck_eq("below(LONG_MIN) too", {
        random.seed(42);
        random.below(0 - 9223372036854775807 - 1)
    }, 0);

    random.seed(7);
    let bad = 0;
    let i = 0;
    while (i < 2000) {
        let v = random.below(10);
        if (v < 0 || v > 9) { bad = bad + 1 };
        i = i + 1
    };
    test.ck_eq("2000 draws from below(10) all land in 0..9", bad, 0);

    random.seed(8);
    let big = 0;
    i = 0;
    while (i < 2000) {
        let v = random.below(1000000);
        if (v < 0 || v > 999999) { big = big + 1 };
        i = i + 1
    };
    test.ck_eq("and 2000 from below(1000000) in 0..999999", big, 0);

    // The bias that a plain `% n` would have: rejection sampling means the
    // counts over a whole modulus come out even. This is the property `% n`
    // fails, so it is the one worth asserting.
    test.group("below(n) is unbiased, which % n is not");
    random.seed(11);
    let c0 = 0;
    let c1 = 0;
    let c2 = 0;
    i = 0;
    while (i < 3000) {
        let v = random.below(3);
        if (v == 0) { c0 = c0 + 1 };
        if (v == 1) { c1 = c1 + 1 };
        if (v == 2) { c2 = c2 + 1 };
        i = i + 1
    };
    test.ck("all three outcomes are reached", c0 > 0 && c1 > 0 && c2 > 0,
        "none is unreachable");
    // 3000 draws over 3 buckets: each near 1000. A tolerance of 100 is loose
    // enough that a healthy generator passes it every time and tight enough that
    // a `% n` bias on a 64-bit range would not.
    test.ck("and the counts are within 100 of each other",
        (c0 > 900 && c0 < 1100) && (c1 > 900 && c1 < 1100) && (c2 > 900 && c2 < 1100),
        "each near 1000");

    // ─────────────────────────────────────────── range(lo, hi)
    test.group("range(lo, hi) is INCLUSIVE on both ends");
    // The header comment says inclusive and the code is lo + below(hi - lo + 1),
    // so this checks the module against itself rather than against a guess.
    random.seed(3);
    let lo_ok = true;
    let saw_lo = false;
    let saw_hi = false;
    i = 0;
    while (i < 4000) {
        let v = random.range(5, 7);
        if (v < 5 || v > 7) { lo_ok = false };
        if (v == 5) { saw_lo = true };
        if (v == 7) { saw_hi = true };
        i = i + 1
    };
    test.ck("4000 draws from range(5, 7) stay inside 5..7", lo_ok, "inclusive");
    test.ck("and both ends are reachable", saw_lo && saw_hi,
        "so 5 and 7 are IN, not just tolerated");
    test.ck_eq("a one-wide range is that one value",
        {
            random.seed(4);
            random.range(9, 9)
        }, 9);
    // hi < lo answers lo rather than trapping or wrapping: the header says
    // `if (hi < lo) { return lo }`, so an inverted range is its own lower bound.
    test.ck_eq("an inverted range answers lo, not a trap",
        {
            random.seed(4);
            random.range(9, 2)
        }, 9);

    // The width is hi - lo + 1, and that WRAPS for a range spanning most of the
    // word. range(5, LONG_MAX) has a true width of 2^63 - 4, which is above
    // below's 2^62 span and so reached the hanging path: this used to never
    // return at all. range(LONG_MIN, LONG_MAX) is the 2^64 case, where the wrap
    // lands on 0 and the answer was always lo -- inside the range, so not wrong
    // on its own terms, but for an accident of arithmetic rather than a decision.
    test.ck_eq("range(5, LONG_MAX) answers lo instead of hanging",
        random.range(5, 9223372036854775807 - 1), 5);
    test.ck("and it does return", {
        let v = random.range(5, 9223372036854775807 - 1);
        v >= 5 && v <= 9223372036854775807 - 1
    }, "in the range");
    test.ck("range(LONG_MIN, LONG_MAX) is one of its endpoints", {
        random.seed(1);
        let v = random.range(0 - 9223372036854775807 - 1, 9223372036854775807 - 1);
        v == 0 - 9223372036854775807 - 1 || v == 9223372036854775807 - 1
    }, "the width is 2^64 and cannot be drawn");
    test.ck("and it is inside the range", {
        random.seed(1);
        let v = random.range(0 - 9223372036854775807 - 1, 9223372036854775807 - 1);
        v >= 0 - 9223372036854775807 - 1 && v <= 9223372036854775807 - 1
    }, "a 2^64 span has no drawable width, so an endpoint");
    // A range whose width is exactly below's 2^62 span is the widest one that
    // draws. Its width is 2^62 over 500 draws, so the two ends are simply not
    // going to come up -- asserting otherwise asks for a coincidence -- and the
    // property worth asserting is that every answer is inside. A narrower range
    // is where both ends are checkable, which is what the 5..7 case above does.
    test.ck("the widest drawable range stays inside itself", {
        random.seed(9);
        let lo = 0 - 4611686018427387904;
        let hi = 0 - 1;
        let ok = true;
        let i = 0;
        while (i < 500) {
            let v = random.range(lo, hi);
            if (v < lo || v > hi) { ok = false };
            i = i + 1
        };
        ok
    }, "500 draws from a range of width 2^62, all inside");

    // ─────────────────────────────────────────── chance(pct)
    test.group("chance(pct)");
    test.ck("chance(0) is never true", !random.chance(0), "0 percent");
    test.ck("chance(100) is always true", random.chance(100), "100 percent");
    random.seed(6);
    let trues = 0;
    i = 0;
    while (i < 2000) {
        if (random.chance(50)) { trues = trues + 1 };
        i = i + 1
    };
    test.ck("2000 draws at 50% are near half", trues > 850 && trues < 1150,
        "loose enough to pass every run, tight enough to catch a stuck stream");
    test.ck("chance is reproducible under a seed", {
        random.seed(21);
        let x1 = random.chance(37);
        let x2 = random.chance(37);
        random.seed(21);
        x1 == random.chance(37) && x2 == random.chance(37)
    }, "the same two answers");

    // ─────────────────────────────────────────── state / set_state
    test.group("the state handle: two independent streams");
    // This is what makes a second stream possible without a second module, and
    // it is the capability mud's per-session generator needs.
    // state() is the state the NEXT draw will start from, so a state captured
    // right after seeding replays the FIRST draw -- captured after one draw it
    // replays the second. Both are checked, because getting this backwards is
    // the easy mistake and it fails silently.
    random.seed(100);
    let s_first = random.state();
    let d1 = random.next();
    let s_second = random.state();
    let d2 = random.next();
    random.set_state(s_first);
    test.ck_eq("a state captured after seeding replays the first draw",
        random.next(), d1);
    random.set_state(s_second);
    test.ck_eq("and one captured after a draw replays the next", random.next(), d2);
    test.ck("the two states are not equal", s_first != s_second,
        "so the distinction is real and not an accident of the values");

    // two streams interleaved, by saving and restoring around each draw
    random.seed(200);
    let d_a1 = random.next();
    let sa = random.state();
    let d_a2 = random.next();
    random.seed(300);
    let d_b1 = random.next();
    let sb = random.state();
    let d_b2 = random.next();
    random.set_state(sa);
    test.ck_eq("stream A resumes at its second draw", random.next(), d_a2);
    random.set_state(sb);
    test.ck_eq("stream B resumes at its second draw", random.next(), d_b2);
    test.ck("and the two streams are not the same", d_a1 != d_b1,
        "different seeds, different streams");
    // and A is undisturbed by B having run in between
    random.set_state(sa);
    test.ck_eq("A did not move while B was being drawn", random.next(), d_a2);

    // ─────────────────────────────────────────── reproducibility as a whole
    test.group("a whole sequence is reproducible");
    // The property a golden file depends on.
    let seq1: [long] = [];
    let seq2: [long] = [];
    random.seed(12345);
    i = 0;
    while (i < 50) {
        seq1 += random.below(1000);
        i = i + 1
    };
    random.seed(12345);
    i = 0;
    while (i < 50) {
        seq2 += random.below(1000);
        i = i + 1
    };
    let same = true;
    i = 0;
    while (i < 50) {
        if (seq1[i] != seq2[i]) { same = false };
        i = i + 1
    };
    test.ck("50 draws from one seed match exactly", same, "the golden-file property");
    test.ck_eq("and there are 50 of them", seq1.length, 50);

    random.seed(54321);
    let differs = 0;
    i = 0;
    while (i < 50) {
        if (random.below(1000) != seq1[i]) { differs = differs + 1 };
        i = i + 1
    };
    test.ck("a different seed gives a different sequence", differs > 40,
        "not one draw in fifty the same");

    // ─────────────────────────────────────────── against splitmix64 itself
    //
    // Every check above is a PROPERTY: two draws differ, a seed replays, the
    // counts come out even. Each of those would also hold for a generator that is
    // wrong in some way nobody thought to ask about, and a property cannot tell
    // you which. So this block pins the VALUES -- and the reference is
    // splitmix64 computed in exact 64-bit arithmetic, not a golden file written
    // from this module's own output, which would only certify that it has not
    // changed.
    //
    // The reference needs the module's convention spelled out. splitmix64 mixes
    // the state it is handed, and this module both offsets the seed by the
    // golden ratio (in seed) and advances before mixing (in next), so the draw
    // for seed(v) is mix(v + 2*GOLDEN), the second mix(v + 3*GOLDEN), and so on.
    // An earlier draft of this block seeded twice and compared against
    // mix(v + GOLDEN), which is why the first line below is the FIRST draw and
    // not a repeat of it -- the module advances st inside next(), so seeding once
    // and drawing twice is one stream, and re-seeding is draw one again.
    test.group("the VALUES, against splitmix64 in exact 64-bit arithmetic");
    test.ck("seed 1, first six draws", stream_of(1, 6) == [
        -4689498862643123097, -534904783426661026, 8196980753821780235,
        8195237237126968761, -4373826470845021568, -2262517385565684571
    ], "splitmix64 with the seed offset applied twice");
    test.ck("seed 2, first three", stream_of(2, 3) == [
        -4627371582388691390, -7459160825568275665, -4327252827158612380
    ], "a second seed, a third stream");
    test.ck("seed 0, first three", stream_of(0, 3) == [
        7960286522194355700, 487617019471545679, -537132696929009172
    ], "seed 0 is not a fixed point and mixes like any other");
    test.ck("a negative seed", stream_of(0 - 5, 2) == [
        -8161798454662654712, -2167467587980096447
    ], "the shifts are >>> so the sign does not change the mixer");
    test.ck("seed 2^62", stream_of(4611686018427387904, 2) == [
        -4798756103566256131, -305740179795585657
    ], "the sign bit set, which >>> must ignore");
    test.ck("seed LONG_MIN", stream_of(0 - 9223372036854775807 - 1, 2) == [
        -4292029157624213486, 7036458801432265024
    ], "every bit set: a >> would carry the sign down and fail this");

    // below(n) is the raw stream masked to 62 bits and rejected above the largest
    // whole multiple of n -- so its values follow from the stream, and the
    // expected ones are computed from it the same way.
    test.group("below(n), derived from the raw stream");
    test.ck("below(4) from seed 42", bounded_of(42, 4, 20) == [
        3, 2, 0, 2, 2, 1, 0, 1, 2, 3, 2, 2, 3, 0, 2, 1, 1, 3, 0, 0
    ], "masked to 62 bits, then modulo, with rejection");
    test.ck("below(1000) from seed 42", bounded_of(42, 1000, 6) == [
        291, 954, 860, 250, 350, 925
    ], "a modulus that does not divide the span, so rejection runs");
    test.ck("below(2^61) from seed 42", bounded_of(42, 2305843009213693952, 4) == [
        643983082913198339, 527597730035375954, 1737512041830867860, 701532786141963250
    ], "the sign bit of the masked draw is where the difference is");

    // state() is st itself, so these two pin the offset arithmetic rather than
    // the mixer.
    random.seed(1);
    test.ck_eq("state after seed(1) is the offset seed", random.state(),
        -7046029254386353130);
    random.next();
    test.ck_eq("and after one draw it has advanced by the golden ratio",
        random.state(), 4354685564936845355);

    return test.report();
};

// n draws from one seed, so a block can be compared as a list.
def stream_of(v: long, n: long) -> [long] {
    random.seed(v);
    let out: [long] = [];
    let i = 0;
    while (i < n) {
        out += random.next();
        i = i + 1
    };
    out
};

// n draws of below(k) from one seed.
def bounded_of(v: long, k: long, n: long) -> [long] {
    random.seed(v);
    let out: [long] = [];
    let i = 0;
    while (i < n) {
        out += random.below(k);
        i = i + 1
    };
    out
};
exit(main());
