// ids.y -- the arithmetic of "invalid product IDs" (AoC 2025, day 2).
//
// A product ID is *invalid* when its decimal digits are some block of
// digits repeated: twice for part 1, two or more times for part 2.  So
// the whole question is a periodicity question on the digit string, and
// two facts turn it into integer arithmetic with no strings at all:
//
//   (1) ROTATION.  An L-digit number n has period p exactly when
//         n * 10^p == n   (mod 10^L - 1)
//       because 10^L - 1 is one string of nines: modulo it, multiplying
//       by ten is a cyclic left rotation of the L digits.  So "is this
//       block repeated?" is a modular multiplication, and the answer for
//       every n in a range can be decided without ever building a
//       digit string.  That is the brute-force path (brute).
//
//   (2) GENERATION.  Every ID is periodic for its MINIMAL period p0, and
//       then n = b * rep where b is the p0-digit block and
//         rep = 1 + 10^p0 + 10^(2 p0) + ... + 10^((k-1) p0),  k = L / p0.
//       For a fixed (L, p) the b that work are *all* p-digit numbers, so
//       the candidate set is one contiguous interval of IDs
//         [ 10^(p-1) * rep , (10^p - 1) * rep ]
//       and the whole ID space can be walked by (digit length, period)
//       instead of by integer.  This never touches a valid ID, so a
//       10^10-wide range costs the same as a 10-wide one.
//
// Part 1 additionally has a closed form used as a third opinion (ap_walk):
// the IDs that are *some block twice* are exactly { b*(10^h+1) :
// b in [10^(h-1), 10^h-1] } for each half-length h -- contiguous -- so
// each range contributes an arithmetic progression whose sum is
// cnt*(first+last)/2.  No primitivity filter there: "twice" is about the
// written form, and 1111 is 11 twice whatever 11 itself is.
//
// NO SORT BUILTIN EXISTS, so sort_spans below is a hand-written
// insertion sort; `fs.sort_names` sorts strings, not records.
//
// ── bounds, and why ──────────────────────────────────────────────────
// MAXDIG = 17 digits.  The rotation test reduces modulo 10^L - 1 and
// multiplies by ten, so it needs (10^L - 1) * 10 < 2^63, which holds to
// L = 18 but not to L = 19; 17 is the largest length for which rep_of
// and every candidate b*rep also stay inside a signed long.  A longer
// number in the input is rejected with a message (never a trap).  Sums
// are plain longs: an input whose ANSWER exceeds 2^63 is out of scope,
// and the real input's answers are ~7e10.

const MAXDIG: long = 17;

// P10[d] = 10^d for d in 0..MAXDIG.  Module level and filled once by
// init(), because a literal array inside a loop body allocates per
// iteration and this table is read in the innermost loop of every method.
let P10: [long] = [1; 18];

// A half-open pair of inclusive bounds: the IDs lo..hi.  lo > hi is a
// legal, empty range (the solver reports it and contributes nothing).
type Span = { lo: long, hi: long };

// What one pass over the ranges produced.
type Res = { sum: long, count: long, seen: long };

// What the generator produced.  `tw`/`twc` are the part-1 subset found
// by the generator itself and `th`/`thc` the part-2-only rest, so part 2
// decomposes into part 1 plus these -- an invariant the property check
// asserts.
//
// The split is by the PARITY of the repeat count k = L/p (p the MINIMAL
// period), not by k == 2, and that distinction is the whole subtlety of
// part 1.  "Some block twice" means "has period L/2", and with L = p*k
// that holds exactly when k is even -- because k even means L/2 is a
// whole number of periods, so the half-size block exists.  So 1111 is
// part 1 (k = 4: it is 11 twice) while 121212 is not (k = 3, odd, and
// six digits do not split into two equal halves).  Bucketing by k == 2
// would put 1111 in the part-2-only bucket and lose it from part 1
// entirely, which is what the first version of this file did: it
// disagreed with the brute force on 1001-1111 and the property check
// caught it.
//
// `cand` counts candidate blocks examined, `lo`/`hi`/`got` the smallest
// and largest ID emitted (used to prove a pass found something at all
// rather than comparing two absent values).
type Gen = { sum: long, count: long, tw: long, twc: long, th: long,
             thc: long, cand: long, lo: long, hi: long, got: long,
             perlen: [long], perlen_n: [long] };

// Parse errors are reported through this rather than an exit, so one
// parse pass can serve every caller; empty means fine.
let perr: str = "";

def init() -> void {
    let i = 1;
    while (i <= MAXDIG) {
        P10[i] = P10[i - 1] * 10;
        i = i + 1
    }
};

def is_digit(c: long) -> bool { c >= 48 && c <= 57 };

def is_space(c: long) -> bool { c == 32 || c == 10 || c == 13 || c == 9 };

// ndigits(n) -> long -- decimal digits of n; 0 has one.
def ndigits(n: long) -> long {
    if (n < 1) { return 1 };
    let d = 0;
    let t = n;
    while (t > 0) {
        d = d + 1;
        t = t / 10
    };
    d
};

// rot10(x, m, times) -> long -- x * 10^times mod m, by repeated
// multiplication by ten.
//
// x is reduced first, and that is about range, not arithmetic: the
// identity (x*10^k) mod m == ((x mod m) * 10^k) mod m holds either way
// (removing the reduction changes no answer -- verified by injecting it
// and watching --check stay green), but without it the running value
// starts at x and the first multiply can exceed 2^63 for a wide m, which
// is a trap rather than a wrong number.  Reducing first also gives the
// comparison in has_period something to match for an all-nines number:
// n = m has n mod m == 0, and 99 really does have period 1.
def rot10(x: long, m: long, times: long) -> long {
    let r = x % m;
    let i = 0;
    while (i < times) {
        r = (r * 10) % m;
        i = i + 1
    };
    r
};

// has_period(n, l, p) -> bool -- n's l digits are a p-digit block
// repeated l/p times.  p must divide l.
def has_period(n: long, l: long, p: long) -> bool {
    let m = P10[l] - 1;
    rot10(n, m, p) == n % m
};

// primitive(b, p) -> bool -- b's p digits are NOT themselves a repeat.
//
// Needed so the generator emits each ID exactly once: without it, 1111
// would be produced both as 11 twice (L=4, p=2) and as 1 four times
// (L=4, p=1), and be counted twice.  Requiring the block to be primitive
// makes p the minimal period, which is unique.
def primitive(b: long, p: long) -> bool {
    let m = P10[p] - 1;
    let t = b % m;
    let q = 1;
    let ok = true;
    while (q < p && ok) {
        if (p % q == 0 && rot10(b, m, q) == t) { ok = false };
        q = q + 1
    };
    ok
};

// rep_of(p, k) -> long -- 1 + 10^p + ... + 10^((k-1)p): multiplying a
// p-digit block by this repeats it k times.
def rep_of(p: long, k: long) -> long {
    let r = 0;
    let t = 1;
    let j = 0;
    while (j < k) {
        r = r + t;
        t = t * P10[p];
        j = j + 1
    };
    r
};

// ── parsing ──────────────────────────────────────────────────────────
//
// The input is ONE line of "lo-hi" fields separated by commas, and the
// field count is not fixed by anything, so nothing here assumes one: the
// text is walked character by character and a field is read as "digits,
// dash, digits".  Wrapping, a trailing comma, and stray spaces are all
// skipped rather than counted as ranges.  A number with a leading zero
// ("0101") is read as the integer 101, which is what the statement means
// by "0101 is not an ID": the digits of the ID are the digits of 101.
def parse(text: str) -> [Span] {
    let out: [Span] = [];
    perr = "";
    let n = text.length;
    let i = 0;
    while (i < n) {
        let c = text[i];
        if (is_digit(c)) {
            let lo = 0;
            let got = 0;
            while (i < n && is_digit(text[i])) {
                if (got >= MAXDIG) {
                    perr = "an ID has more than " + tostring(MAXDIG) + " digits";
                    return out
                };
                lo = lo * 10 + (text[i] - 48);
                got = got + 1;
                i = i + 1
            };
            while (i < n && is_space(text[i])) { i = i + 1 };
            if (i >= n || text[i] != 45) {
                perr = "expected '-' after the first ID " + tostring(lo);
                return out
            };
            i = i + 1;
            while (i < n && is_space(text[i])) { i = i + 1 };
            if (i >= n || is_digit(text[i]) == false) {
                perr = "expected the last ID after '-' in the range that starts " + tostring(lo);
                return out
            };
            let hi = 0;
            got = 0;
            while (i < n && is_digit(text[i])) {
                if (got >= MAXDIG) {
                    perr = "an ID has more than " + tostring(MAXDIG) + " digits";
                    return out
                };
                hi = hi * 10 + (text[i] - 48);
                got = got + 1;
                i = i + 1
            };
            // A record literal here is one allocation per range (32 of
            // them for the real input), and each push needs its OWN
            // record: the array holds references, so pushing a shared
            // `cur` and mutating it later would rewrite earlier entries.
            out += { lo: lo, hi: hi }
        } else if (is_space(c) || c == 44) {
            i = i + 1
        } else {
            perr = "unexpected byte " + tostring(c) + " in the input";
            return out
        }
    };
    out
};

// sort_spans(xs) -> void -- insertion sort by (lo, hi), in place.
//
// Hand-written because Y has no sort for records.  Arrays are
// references, so `v` holds a pointer to a record and the swap moves
// pointers; no field is ever written through one, which is what keeps
// this sound.
def sort_spans(xs: [Span]) -> void {
    let i = 1;
    while (i < len(xs)) {
        let v = xs[i];
        let j = i - 1;
        let moved = true;
        while (j >= 0 && moved) {
            let w = xs[j];
            if (w.lo > v.lo || (w.lo == v.lo && w.hi > v.hi)) {
                xs[j + 1] = w;
                j = j - 1
            } else {
                moved = false
            }
        };
        xs[j + 1] = v;
        i = i + 1
    }
};

// merge(xs) -> [Span] -- the union of the ranges as disjoint spans,
// sorted, touching ones joined (b.hi + 1 == c.lo is the same set of
// IDs as writing them as one range).
//
// Merging is what makes "add up all the invalid IDs that appear in the
// ranges" well defined: without it an ID in two ranges is counted
// twice.  Empty ranges (lo > hi) are dropped and counted by the caller.
def merge(xs: [Span]) -> [Span] {
    sort_spans(xs);
    let out: [Span] = [];
    let i = 0;
    while (i < len(xs)) {
        let s = xs[i];
        i = i + 1;
        if (s.lo <= s.hi) {
            let lo = s.lo;
            let hi = s.hi;
            let more = true;
            while (more && i < len(xs)) {
                let t = xs[i];
                if (t.lo <= hi + 1) {
                    if (t.hi > hi) { hi = t.hi };
                    i = i + 1
                } else {
                    more = false
                }
            };
            out += { lo: lo, hi: hi }
        }
    };
    out
};

def span_total(xs: [Span]) -> long {
    let t = 0;
    let i = 0;
    while (i < len(xs)) {
        if (xs[i].lo <= xs[i].hi) { t = t + (xs[i].hi - xs[i].lo + 1) };
        i = i + 1
    };
    t
};

def empty_count(xs: [Span]) -> long {
    let t = 0;
    let i = 0;
    while (i < len(xs)) {
        if (xs[i].lo > xs[i].hi) { t = t + 1 };
        i = i + 1
    };
    t
};

// disjoint(xs) -> bool -- no two spans share an ID.  Every counting
// method below assumes it, so the property check asserts it rather than
// trusting it.
def disjoint(xs: [Span]) -> bool {
    let i = 1;
    while (i < len(xs)) {
        if (xs[i].lo <= xs[i - 1].hi) { return false };
        i = i + 1
    };
    true
};

// ── method A: element by element, the rotation test ──────────────────
//
// Every ID in every range is examined once.  This is the slow, obvious
// method; it exists to be the independent opinion on the other two, and
// it needs no theory beyond (1) above.
def brute(xs: [Span], part: long) -> Res {
    let sum: long = 0;
    let count: long = 0;
    let seen: long = 0;
    let i = 0;
    while (i < len(xs)) {
        let lo = xs[i].lo;
        let hi = xs[i].hi;
        i = i + 1;
        let n = lo;
        while (n <= hi) {
            seen = seen + 1;
            let l = ndigits(n);
            let hit = false;
            if (part == 1) {
                if (l % 2 == 0) { hit = has_period(n, l, l / 2) }
            } else {
                let p = 1;
                while (p * 2 <= l && hit == false) {
                    if (l % p == 0 && has_period(n, l, p)) { hit = true };
                    p = p + 1
                }
            };
            if (hit) {
                sum = sum + n;
                count = count + 1
            };
            n = n + 1
        }
    };
    { sum: sum, count: count, seen: seen }
};

// ── method C: part 1 only, the contiguous arithmetic progression ─────
//
// For half-length h the IDs that are *some* block twice are
// { b * (10^h + 1) : 10^(h-1) <= b < 10^h } -- one contiguous interval,
// because the multiplier is fixed and b is contiguous.  Intersecting
// that with a range gives a contiguous run of b, whose IDs sum in closed
// form.  Distinct h give distinct digit lengths, so nothing is counted
// twice.
def ap_walk(xs: [Span]) -> Res {
    let sum: long = 0;
    let count: long = 0;
    let seen: long = 0;
    let h = 1;
    while (2 * h <= MAXDIG) {
        let step = P10[h] + 1;
        let blo = P10[h - 1];
        let bhi = P10[h] - 1;
        let i = 0;
        while (i < len(xs)) {
            let lo = xs[i].lo;
            let hi = xs[i].hi;
            i = i + 1;
            if (lo <= hi) {
                // b * step in [lo, hi]  <=>  b in [ceil(lo/step), floor(hi/step)]
                let b0 = lo / step;
                if (b0 * step < lo) { b0 = b0 + 1 };
                let b1 = hi / step;
                if (b0 < blo) { b0 = blo };
                if (b1 > bhi) { b1 = bhi };
                if (b1 >= b0) {
                    let cnt = b1 - b0 + 1;
                    // cnt*(b0+b1) is always even: cnt odd => b1-b0 even =>
                    // b0+b1 even.  So the division below is exact.
                    sum = sum + cnt * (b0 + b1) / 2 * step;
                    count = count + cnt;
                    seen = seen + cnt
                }
            }
        };
        h = h + 1
    };
    { sum: sum, count: count, seen: seen }
};

// ── method B: generate the IDs, by (digit length, period) ───────────
//
// Walks (L, p) with p a proper divisor of L, intersects the block
// interval [10^(p-1), 10^p-1] (scaled by rep) with each range, and keeps
// the primitive blocks.  Every ID is emitted exactly once, and no valid
// ID is ever looked at.
def gen(xs: [Span]) -> Gen {
    let sum: long = 0;
    let count: long = 0;
    let tw: long = 0;
    let twc: long = 0;
    let th: long = 0;
    let thc: long = 0;
    let cand: long = 0;
    let glo: long = 0;
    let ghi: long = 0;
    let got: long = 0;
    let perlen: [long] = [0; 18];
    let perlen_n: [long] = [0; 18];
    let l = 2;
    while (l <= MAXDIG) {
        let p = 1;
        while (p * 2 <= l) {
            if (l % p == 0) {
                let k = l / p;
                let rep = rep_of(p, k);
                let blo = P10[p - 1];
                let bhi = P10[p] - 1;
                let i = 0;
                while (i < len(xs)) {
                    let lo = xs[i].lo;
                    let hi = xs[i].hi;
                    i = i + 1;
                    // cheap reject: no l-digit ID can be in this range
                    if (lo <= hi && hi >= P10[l - 1] && lo < P10[l]) {
                        let b0 = lo / rep;
                        if (b0 * rep < lo) { b0 = b0 + 1 };
                        let b1 = hi / rep;
                        if (b0 < blo) { b0 = blo };
                        if (b1 > bhi) { b1 = bhi };
                        let b = b0;
                        while (b <= b1) {
                            cand = cand + 1;
                            if (primitive(b, p)) {
                                let n = b * rep;
                                sum = sum + n;
                                count = count + 1;
                                perlen[l] = perlen[l] + n;
                                perlen_n[l] = perlen_n[l] + 1;
                                if (k % 2 == 0) {
                                    // even repeat count => the digits also
                                    // split into two equal halves => part 1
                                    tw = tw + n;
                                    twc = twc + 1
                                } else {
                                    th = th + n;
                                    thc = thc + 1
                                };
                                if (got == 0) {
                                    glo = n;
                                    ghi = n;
                                    got = 1
                                } else {
                                    if (n < glo) { glo = n };
                                    if (n > ghi) { ghi = n }
                                }
                            };
                            b = b + 1
                        }
                    }
                }
            };
            p = p + 1
        };
        l = l + 1
    };
    { sum: sum, count: count, tw: tw, twc: twc, th: th, thc: thc,
      cand: cand, lo: glo, hi: ghi, got: got,
      perlen: perlen, perlen_n: perlen_n }
};

// ── the pipeline ─────────────────────────────────────────────────────
//
// ONE function does parse -> merge -> both parts, and both day02.y and
// checks.y call it.  That is not tidiness, it is the whole point of the
// property check: when each of them assembled the pipeline from the same
// pieces itself, a defect injected into day02.y's use of merge() was
// completely invisible to the check (the check merged correctly and
// agreed with itself, 61 checks green, on a solver that double-counts
// every overlapping range).
type Answer = {
    ok: bool,
    msg: str,
    raw: [Span],
    merged: [Span],
    part1: Res,
    part2: Res,
    g: Gen,
    total: long,
    empties: long
};

// solve(text, want_brute) -> Answer -- the whole program, minus printing.
//
// want_brute picks which method fills part1/part2: true walks every ID in
// every range (slow, independent), false uses the generator (fast).  The
// generator's own numbers are always computed, because the property check
// needs them either way.
def solve(text: str, want_brute: bool) -> Answer {
    init();
    let raw = parse(text);
    if (perr != "") {
        return { ok: false, msg: perr, raw: raw, merged: [], part1: { sum: 0, count: 0, seen: 0 },
                 part2: { sum: 0, count: 0, seen: 0 }, g: gen([]), total: 0, empties: 0 }
    };
    let merged = merge(raw);
    let g = gen(merged);
    let empties = empty_count(raw);
    let total = span_total(merged);
    let r1: Res = ap_walk(merged);
    let r2: Res = { sum: g.sum, count: g.count, seen: g.cand };
    if (want_brute) {
        r1 = brute(merged, 1);
        r2 = brute(merged, 2)
    };
    { ok: true, msg: "", raw: raw, merged: merged, part1: r1, part2: r2,
      g: g, total: total, empties: empties }
};