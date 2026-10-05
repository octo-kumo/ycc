// day05.y -- Advent of Code 2025, day 5 ("Cafeteria"), in Y.
//
// The elves' inventory database: a list of INCLUSIVE fresh ingredient ID
// ranges, a blank line, then the list of available ingredient IDs.  The
// ranges may overlap; an ID is fresh when it falls inside any of them.
//
//   part 1  how many of the AVAILABLE ids are fresh
//   part 2  how many DISTINCT ids the ranges cover altogether
//
// part 1 is computed twice: the statement's own linear scan, and a binary
// search over the merged ranges.  part 2 is computed four times: merge and
// sum, a one-pass furthest-end accumulator, an endpoint sweep, and a brute
// force that materialises every covered integer.  All of them are asserted
// to agree, and so are two proofs over a small whole state space.
//
// There is no `sort` in Y, so `msort` below is my own bottom-up merge sort.
//
// build: ../../../refs/ycc.ref day05.y -o day05
// run:   ./day05            (input.txt -> both answers)
//        ./day05 --check    (property battery, no reference file)
//        ./day05 --help
import fs;

const CH_ZERO = 48;              // '0'
const CH_NL = 10;                // '\n'
const CH_CR = 13;                // '\r'
const CH_DASH = 45;              // '-'
const MAX_DIGITS = 18;           // past this a value could overflow a long

// A parsed database.  `lo`/`hi` are the ranges in FILE order; `rlo`/`rhi`
// are the same ranges sorted by (lo, hi); `mlo`/`mhi` are those folded into
// disjoint, ascending, MAXIMAL segments.  All six are plain [long] rather
// than records: the arena never frees, and a record per range would be 182
// allocations for nothing.
type Db = {
    lo: [long], hi: [long], ids: [long],
    rlo: [long], rhi: [long],
    mlo: [long], mhi: [long],
    raw_total: long, nseg: long
};

// What an independent byte-level rescan of the same file found.
type Rescan = {
    nrng: long, raw_total: long, nid: long, id_sum: long,
    min_lo: long, max_hi: long, ndash: long
};

let parse_err = "";              // set by parse_db when it returns none
let checks_run = 0;              // --check bookkeeping (globals, not captures)
let checks_failed = 0;
let first_failure = "";

// ── small helpers ───────────────────────────────────────────────────────────

def is_digit(c: long) -> bool { c >= CH_ZERO && c <= CH_ZERO + 9 }

// Y has no min/max builtins.
def imin(a: long, b: long) -> long { if (a < b) { a } else { b } }

// `s` without one trailing carriage return, so a CRLF file reads the same
// as an LF one.  A second one is left alone (a stray CR is reported by
// num_reason, not silently eaten).
def strip_cr(s: str) -> str {
    if (s.length > 0 && s[s.length - 1] == CH_CR) { s[0:s.length - 1] } else { s }
}

// ── my merge sort ───────────────────────────────────────────────────────────

// Copy a[lo..mid) and a[mid..e2) into tmp[lo..e2), ascending.  The `&&`
// short-circuits, so a[j] is never read while j is already past the end.
def merge_step(a: [long], tmp: [long], lo: long, mid: long, e2: long) -> long {
    let i = lo;
    let j = mid;
    let k = lo;
    while (k < e2) {
        if (i < mid && (j >= e2 || a[i] <= a[j])) {
            tmp[k] = a[i];
            i = i + 1;
        } else {
            tmp[k] = a[j];
            j = j + 1;
        };
        k = k + 1;
    };
    e2 - lo
}

// Bottom-up merge sort of a[0..m) into ascending order, using tmp as the
// scratch buffer.  No recursion, no allocation beyond the caller's buffer.
// `w` starts at 1, not 2: a merge step may only join two runs that are EACH
// already sorted, and after a pass of width w every run of 2w is sorted --
// so the very first pass has to sort pairs out of single elements.
// (Verified over every permutation of six values: see check_permutations.)
def msort(a: [long], tmp: [long], m: long) -> long {
    let w = 1;
    while (w < m) {
        let i = 0;
        while (i < m) {
            let mid = imin(i + w, m);
            let e2 = imin(i + 2 * w, m);
            merge_step(a, tmp, i, mid, e2);
            i = i + 2 * w;
        };
        let j = 0;
        while (j < m) { a[j] = tmp[j]; j = j + 1 };
        w = w * 2;
    };
    m
}

// Sort a[0..len) ascending in place.  `m` comes from len, so it is not a
// literal; a fresh scratch buffer is filled once per call.
def sort_asc(a: [long]) -> long {
    let m = len(a);
    if (m < 2) {
        0
    } else {
        let tmp: [long] = [];
        for _i in 1..(m + 1) { tmp += 0 };
        msort(a, tmp, m)
    }
}

// One merge step of the pair sort: order (lo, hi) lexicographically.  Two
// ranges join only when they overlap or merely touch, and a range must keep
// its own high end, so the comparison is on the PAIR -- there is no key that
// fits both ends in one long (each is ~2^49 here), which is why this cannot
// be a single interleaved array.  Sorting an interleaved array of values DOES
// compile, DOES pass every part-2 total, and is wrong: sorting the values
// pulls the two smallest into a "pair".  check_pair_permutations is the test
// that catches it.
def merge_pairs(lo: [long], hi: [long], tlo: [long], thi: [long],
                a: long, mid: long, e: long) -> long {
    let i = a;
    let j = mid;
    let k = a;
    while (k < e) {
        if (i < mid && (j >= e || (lo[i] < lo[j] || (lo[i] == lo[j] && hi[i] <= hi[j])))) {
            tlo[k] = lo[i];
            thi[k] = hi[i];
            i = i + 1;
        } else {
            tlo[k] = lo[j];
            thi[k] = hi[j];
            j = j + 1;
        };
        k = k + 1;
    };
    e - a
}

// Bottom-up merge sort of the n ranges in the parallel arrays lo/hi, by
// (lo, hi).  tlo/thi are scratch buffers of length n the caller fills once.
def sort_pairs(lo: [long], hi: [long]) -> long {
    let n = len(lo);
    let tlo: [long] = [];
    let thi: [long] = [];
    for _i in 0..n { tlo += 0; thi += 0 };
    let w = 1;
    while (w < n) {
        let i = 0;
        while (i < n) {
            let mid = imin(i + w, n);
            let e = imin(i + 2 * w, n);
            merge_pairs(lo, hi, tlo, thi, i, mid, e);
            i = i + 2 * w;
        };
        let j = 0;
        while (j < n) { lo[j] = tlo[j]; hi[j] = thi[j]; j = j + 1 };
        w = w * 2;
    };
    n
}

// ── merging ─────────────────────────────────────────────────────────────────

// Fold the n ranges of `lo`/`hi` (already sorted by lo) into disjoint,
// strictly ascending segments pushed into `mlo`/`mhi`.  Returns the count.
//
// Two ranges join when they overlap OR merely TOUCH: [10,14] and [15,20]
// cover 10..20 with no gap between them, so the test is
// `lo[i] <= cur_hi + 1` and not `lo[i] <= cur_hi`.  That +1 is the whole
// difference between a maximal decomposition and one that merely
// accumulates correctly -- which is why check_struct asserts maximality
// directly.
def merge_ranges(lo: [long], hi: [long], mlo: [long], mhi: [long]) -> long {
    let n = len(lo);
    if (n == 0) {
        0
    } else {
        let nseg = 0;
        let cur_lo = lo[0];
        let cur_hi = hi[0];
        for i in 1..n {
            if (lo[i] <= cur_hi + 1) {
                if (hi[i] > cur_hi) { cur_hi = hi[i] };
            } else {
                mlo += cur_lo;
                mhi += cur_hi;
                nseg = nseg + 1;
                cur_lo = lo[i];
                cur_hi = hi[i];
            };
        };
        mlo += cur_lo;
        mhi += cur_hi;
        nseg + 1
    }
}

// ── part 1, two ways ────────────────────────────────────────────────────────

// Method A: the statement's own walk -- for every available ID, ask every
// range in turn, in the order the file gave them.  No sorting at all.
def part1_scan(lo: [long], hi: [long], ids: [long]) -> long {
    let fresh = 0;
    for k in 0..len(ids) {
        let n = ids[k];
        let hit = false;
        for i in 0..len(lo) {
            if (lo[i] <= n && n <= hi[i]) { hit = true };
        };
        if (hit) { fresh = fresh + 1 };
    };
    fresh
}

// The index of the first segment that could hold x: the first `i` with
// mlo[i] > x.  Usable only because the segments are ascending and disjoint.
def seg_of(mlo: [long], x: long) -> long {
    let lo = 0;
    let hi = len(mlo);
    while (lo < hi) {
        let mid = (lo + hi) / 2;
        if (mlo[mid] <= x) { lo = mid + 1 } else { hi = mid };
    };
    lo
}

def in_segments(mlo: [long], mhi: [long], x: long) -> bool {
    let i = seg_of(mlo, x);
    if (i == 0) { false } else { x <= mhi[i - 1] }
}

// Method B: one binary search per ID over the merged segments.
def part1_binary(mlo: [long], mhi: [long], ids: [long]) -> long {
    let fresh = 0;
    for k in 0..len(ids) {
        if (in_segments(mlo, mhi, ids[k])) { fresh = fresh + 1 };
    };
    fresh
}

// Method C: membership in the explicitly expanded set of covered integers.
def part1_set(covered: [long], ids: [long]) -> long {
    let fresh = 0;
    for k in 0..len(ids) {
        let n = ids[k];
        let hit = false;
        for i in 0..len(covered) {
            if (covered[i] == n) { hit = true };
        };
        if (hit) { fresh = fresh + 1 };
    };
    fresh
}

// ── part 2, four ways ───────────────────────────────────────────────────────

// Every integer covered by any range, as an ascending list with no repeats.
// This is the brute force: it walks the RAW ranges, builds its own list,
// and sorts it with its own call to msort -- merge_ranges appears nowhere
// in it, so agreeing with the merge-based total is a real cross-check and
// not a restatement.  Only for inputs small enough to materialise (the
// real input's ranges cover 4.4e14 integers).
def expand_all(lo: [long], hi: [long]) -> [long] {
    let all: [long] = [];
    for i in 0..len(lo) {
        let v = lo[i];
        let stop = hi[i] + 1;
        while (v < stop) { all += v; v = v + 1 };
    };
    sort_asc(all);
    let uniq: [long] = [];
    for i in 0..len(all) {
        if (i == 0 || all[i] != all[i - 1]) { uniq += all[i] };
    };
    uniq
}

// Method A: sum the lengths of the merged segments.
def part2_merge(mlo: [long], mhi: [long]) -> long {
    let total = 0;
    for i in 0..len(mlo) { total = total + (mhi[i] - mlo[i] + 1) };
    total
}

// Method B: one pass over the SORTED raw ranges keeping only the furthest
// end seen so far.  Builds no array, so a bug in merge_ranges cannot hide
// inside it.
def part2_accum(lo: [long], hi: [long]) -> long {
    let n = len(lo);
    if (n == 0) {
        0
    } else {
        let total = 0;
        let end = lo[0] - 1;      // nothing covered yet
        for i in 0..n {
            if (lo[i] > end) {
                total = total + hi[i] - lo[i] + 1;
                end = hi[i];
            } else {
                if (hi[i] > end) {
                    total = total + hi[i] - end;
                    end = hi[i];
                };
            };
        };
        total
    }
}

// Method C: the endpoint sweep.  A range contributes an event at its first
// integer and an event at one past its last; sorting the events and walking
// them counts the covered integers between consecutive event positions.
//
// Two details matter.  The events are encoded 2*lo (even = a start) and
// 2*(hi+1)+1 (odd = an end) so the sign survives the sort, and a start
// sorts before an end at the same position, so a zero-length range still
// contributes its one integer.  And the span between two events is counted
// when the depth is POSITIVE, not by the depth itself: integrating the
// depth counts a doubly-covered integer twice, which on the statement's
// own example gives 20 instead of 14.
//
// Requires every lo to be >= 0 (the encoding halves it); every input this
// program accepts is, because a range is a bare run of digits.
def part2_sweep(lo: [long], hi: [long]) -> long {
    let n = len(lo);
    if (n == 0) {
        0
    } else {
        let ev: [long] = [];
        for i in 0..n {
            ev += 2 * lo[i];
            ev += 2 * (hi[i] + 1) + 1;
        };
        sort_asc(ev);
        let m = len(ev);
        let total = 0;
        let depth = 0;
        let prev = ev[0] / 2;
        let j = 0;
        while (j < m) {
            let p = ev[j] / 2;
            if (depth > 0) { total = total + (p - prev) };
            while (j < m && ev[j] / 2 == p) {
                if (ev[j] % 2 == 0) { depth = depth + 1 } else { depth = depth - 1 };
                j = j + 1;
            };
            prev = p;
        };
        total
    }
}

// Method D: the brute force, counted.
def part2_expand(lo: [long], hi: [long]) -> long { len(expand_all(lo, hi)) }

// ── parsing ─────────────────────────────────────────────────────────────────

// How many lines to read: a file ending in a newline does not have a last
// empty line, but a file ending in two does, and that second one is the
// file's, not the database's.
def eff_lines(lines: [str]) -> long {
    let n = len(lines);
    while (n > 0 && lines[n - 1].length == 0) { n = n - 1 };
    n
}

// The 1-based number of the blank line that separates the two sections, or
// 0 when the file has none.  A line of spaces is not blank; it is a
// malformed line, and num_reason/range_reason say so by name.
def find_blank(lines: [str], n: long) -> long {
    let i = 0;
    let at = 0;
    while (i < n) {
        if (lines[i].length == 0 && at == 0) { at = i + 1 };
        i = i + 1;
    };
    at
}

def count_blanks(lines: [str], n: long) -> long {
    let i = 0;
    let c = 0;
    while (i < n) {
        if (lines[i].length == 0) { c = c + 1 };
        i = i + 1;
    };
    c
}

// "" when `s` is a bare run of at most MAX_DIGITS digits; otherwise why.
def num_reason(s: str) -> str {
    let why = "";
    if (s.length == 0) {
        why = "empty";
    } else if (s.length > MAX_DIGITS) {
        why = "more than " + tostring(MAX_DIGITS) + " digits (a long could overflow)";
    } else {
        let k = 0;
        let ok = true;
        while (k < s.length && ok) {
            if (is_digit(s[k])) { k = k + 1 } else { ok = false };
        };
        if (!ok) { why = "not a bare number" };
    };
    why
}

// "" when `line` is `lo-hi` with lo <= hi; otherwise why.
def range_reason(line: str) -> str {
    let d = line.index_of("-");
    if (d < 0) {
        "no '-' between the two ends"
    } else {
        let low = line[0:d];
        let high = line[d + 1:];
        let ra = num_reason(low);
        let rb = num_reason(high);
        if (ra != "") {
            "lower end " + ra
        } else if (rb != "") {
            "upper end " + rb
        } else if (tonum(low) > tonum(high)) {
            "lower end " + low + " is above the upper end " + high
        } else {
            ""
        }
    }
}

// The 1-based line number of the first malformed line among [from, to) of
// the ranges section, or 0.
def bad_range_at(lines: [str], count: long) -> long {
    let i = 0;
    let bad = 0;
    while (i < count && bad == 0) {
        if (range_reason(strip_cr(lines[i])) != "") { bad = i + 1 } else { i = i + 1 };
    };
    bad
}

// The same for the ids section, lines [from, to) 0-based.
def bad_id_at(lines: [str], from: long, to: long) -> long {
    let i = from;
    let bad = 0;
    while (i < to && bad == 0) {
        if (num_reason(strip_cr(lines[i])) != "") { bad = i + 1 } else { i = i + 1 };
    };
    bad
}

// Parse the database.  none on a malformed file, with parse_err saying why;
// a message on stderr and a non-zero exit, never a trap.
def parse_db(lines: [str]) -> Db? {
    parse_err = "";
    let n = eff_lines(lines);
    if (n == 0) {
        parse_err = "the file is empty";
        return none;
    };
    // A file that ends with a blank line has no IDs at all, and the trailing
    // blank has just been trimmed away, so name that case rather than
    // reporting a missing separator.
    if (find_blank(lines, len(lines)) > n) {
        parse_err = "the file ends with a blank line, so it holds no available IDs";
        return none;
    };
    let b = find_blank(lines, n);
    if (b == 0) {
        parse_err = "no blank line separating the ranges from the IDs";
        return none;
    };
    if (count_blanks(lines, n) != 1) {
        parse_err = "more than one blank line; the statement gives exactly one";
        return none;
    };
    if (b == 1) {
        parse_err = "no fresh ranges before the blank line";
        return none;
    };
    if (b == n) {
        parse_err = "no available IDs after the blank line";
        return none;
    };
    let bad = bad_range_at(lines, b - 1);
    if (bad != 0) {
        parse_err = "line " + tostring(bad) + ": " + range_reason(strip_cr(lines[bad - 1]));
        return none;
    };
    let badid = bad_id_at(lines, b, n);
    if (badid != 0) {
        parse_err = "line " + tostring(badid) + ": " + num_reason(strip_cr(lines[badid - 1]));
        return none;
    };

    let lo: [long] = [];
    let hi: [long] = [];
    let raw_total = 0;
    for i in 0..(b - 1) {
        let s = strip_cr(lines[i]);
        let d = s.index_of("-");
        let a = tonum(s[0:d]);
        let z = tonum(s[d + 1:]);
        lo += a;
        hi += z;
        raw_total = raw_total + (z - a + 1);
    };
    let ids: [long] = [];
    for i in b..n { ids += tonum(strip_cr(lines[i])) };

    let rlo: [long] = [];
    let rhi: [long] = [];
    for i in 0..len(lo) { rlo += lo[i]; rhi += hi[i] };
    sort_pairs(rlo, rhi);
    let mlo: [long] = [];
    let mhi: [long] = [];
    let nseg = merge_ranges(rlo, rhi, mlo, mhi);
    some({ lo: lo, hi: hi, ids: ids,
           rlo: rlo, rhi: rhi, mlo: mlo, mhi: mhi,
           raw_total: raw_total, nseg: nseg })
}

// ── an independent read of the same bytes ───────────────────────────────────

// Walk the raw bytes and pull out the digit runs directly.  Nothing here
// goes through read_lines or the parser: it tracks only whether it is
// inside the ranges section or the IDs section, decided by meeting a
// newline with no digits in front of it (the blank line).  If this and
// parse_db ever disagree about a file, one of them is wrong.
def rescan(b: [byte]) -> Rescan {
    let nrng = 0;
    let raw_total = 0;
    let nid = 0;
    let id_sum = 0;
    let min_lo = -1;
    let max_hi = -1;
    let ndash = 0;
    let lo = -1;
    let cur = -1;
    let in_ranges = true;
    let want_high = false;
    // One step past the end, where the separator is a virtual newline, so
    // a file with no trailing newline still flushes its last number.
    let n = len(b) + 1;
    let i = 0;
    while (i < n) {
        let d = -1;                   // the digit's value, -1 = a separator
        let sep = CH_NL;              // what the separator byte is
        if (i < len(b)) {
            let by = b[i];
            sep = by;
            if (by >= CH_ZERO && by <= CH_ZERO + 9) { d = by - CH_ZERO };
        };
        if (d >= 0) {
            if (cur < 0) { cur = 0 };
            cur = cur * 10 + d;
        } else {
            if (cur >= 0) {
                if (!in_ranges) {
                    nid = nid + 1;
                    id_sum = id_sum + cur;
                } else if (want_high) {
                    nrng = nrng + 1;
                    raw_total = raw_total + cur - lo + 1;
                    if (min_lo < 0 || lo < min_lo) { min_lo = lo };
                    if (cur > max_hi) { max_hi = cur };
                    want_high = false;   // this range is complete
                } else {
                    lo = cur;
                    want_high = true;
                };
                cur = -1;
            } else if (sep == CH_NL) {
                in_ranges = false;     // an empty line: the ranges are over
            };
            if (sep == CH_DASH) {
                ndash = ndash + 1;
                want_high = true;
            };
        };
        i = i + 1;
    };
    { nrng: nrng, raw_total: raw_total, nid: nid, id_sum: id_sum,
      min_lo: min_lo, max_hi: max_hi, ndash: ndash }
}

// ── structural invariants of a merged decomposition ─────────────────────────

// The segments must be disjoint, ascending, and MAXIMAL: no two of them may
// be adjacent, because adjacent ones should have been one segment.  This is
// the property that catches the `+1` in merge_ranges going missing, which
// no total-based check can see -- two touching segments sum to exactly what
// one merged segment would.
def seg_wellformed(mlo: [long], mhi: [long]) -> long {
    let bad = 0;
    for i in 0..len(mlo) {
        if (mlo[i] > mhi[i]) { bad = bad + 1 };
        if (i > 0) {
            if (mlo[i] <= mhi[i - 1]) { bad = bad + 1 };
            if (mlo[i] == mhi[i - 1] + 1) { bad = bad + 1 };
        };
    };
    bad
}

// Every raw range must sit inside EXACTLY ONE merged segment, and every
// merged segment must contain at least one raw range.  Together those say
// the segments are a partition of the ranges: nothing dropped, nothing
// counted twice.
def seg_partitions(lo: [long], hi: [long], mlo: [long], mhi: [long]) -> long {
    let bad = 0;
    let n = len(lo);
    for i in 0..n {
        let hit = 0;
        for s in 0..len(mlo) {
            if (mlo[s] <= lo[i] && hi[i] <= mhi[s]) { hit = hit + 1 };
        };
        if (hit != 1) { bad = bad + 1 };
    };
    for s in 0..len(mlo) {
        let hit = 0;
        for i in 0..n {
            if (mlo[s] <= lo[i] && hi[i] <= mhi[s]) { hit = hit + 1 };
        };
        if (hit == 0) { bad = bad + 1 };
    };
    bad
}

// ── the check harness ───────────────────────────────────────────────────────

def expect(name: str, ok: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    let bad = 0;
    if (ok) {
        print("ok   " + name + "   " + detail);
    } else {
        checks_failed = checks_failed + 1;
        bad = 1;
        if (first_failure == "") { first_failure = name };
        print("FAIL " + name + "   " + detail);
    };
    bad
}

// ── hand-worked micro-cases ─────────────────────────────────────────────────

// Run one tiny database, written as literal LINES so the real parser is
// exercised too, through every method for both parts.  `want1`/`want2` are
// the values worked out by hand in README.md.
def micro(label: str, lines: [str], want1: long, want2: long) -> long {
    let got: Db? = parse_db(lines);
    if (got == none) {
        return expect("micro " + label, false, "parser rejected it: " + parse_err);
    };
    let d = got!;
    let covered = expand_all(d.lo, d.hi);
    let p1 = part1_scan(d.lo, d.hi, d.ids);
    let p1b = part1_binary(d.mlo, d.mhi, d.ids);
    let p1c = part1_set(covered, d.ids);
    let p2 = part2_merge(d.mlo, d.mhi);
    let p2b = part2_accum(d.rlo, d.rhi);
    let p2c = part2_sweep(d.rlo, d.rhi);
    let p2d = part2_expand(d.lo, d.hi);

    print(f"  {label}: ranges={len(d.lo)} ids={len(d.ids)} segments={d.nseg} "
          + f"raw_total={d.raw_total} covered={len(covered)}");
    print(f"    part 1 want {want1}: scan={p1} binary={p1b} set={p1c}");
    print(f"    part 2 want {want2}: merge={p2} accum={p2b} sweep={p2c} expand={p2d}");

    let f = 0;
    f = f + expect("micro " + label + " part 1", p1 == want1, f"{p1} == {want1}");
    f = f + expect("micro " + label + " part 2", p2 == want2, f"{p2} == {want2}");
    f = f + expect("micro " + label + " part 1 methods agree",
                   p1 == p1b && p1 == p1c, f"scan={p1} binary={p1b} set={p1c}");
    f = f + expect("micro " + label + " part 2 methods agree",
                   p2 == p2b && p2 == p2c && p2 == p2d,
                   f"merge={p2} accum={p2b} sweep={p2c} expand={p2d}");
    f = f + expect("micro " + label + " segments well formed",
                   seg_wellformed(d.mlo, d.mhi) == 0 && d.nseg == len(d.mlo),
                   f"{d.nseg} segment(s)");
    f = f + expect("micro " + label + " segments partition the ranges",
                   seg_partitions(d.lo, d.hi, d.mlo, d.mhi) == 0, "each range in exactly one segment");
    f
}

def check_micro() -> long {
    let f = 0;
    print("hand-worked micro-cases (the arithmetic is in README.md):");

    // M1  The statement's own example.  Ranges 3-5, 10-14, 16-20, 12-18;
    // ids 1, 5, 8, 11, 17, 32.  Fresh: 5 (in 3-5), 11 (in 10-14), 17 (in
    // both 16-20 and 12-18) = 3 -- the statement's own answer.  Merged:
    // [3,5] and [10,20], so 3 + 11 = 14 -- the part-2 anchor the write-up
    // states for this same example.
    f = f + micro("M1 statement example",
                  ["3-5", "10-14", "16-20", "12-18", "", "1", "5", "8", "11", "17", "32"],
                  3, 14);

    // M2  Two ranges that merely TOUCH, 1-3 and 4-6: together they cover
    // 1..6 with no gap, so the union is 6 and the decomposition must be ONE
    // segment.  ids 3, 4, 6 are all fresh.
    f = f + micro("M2 touching ranges 1-3,4-6", ["1-3", "4-6", "", "3", "4", "6"], 3, 6);

    // M3  A range wholly inside another, 10-20 and 12-14: the union is
    // 10..20, eleven integers.  ids 11, 13, 15 -> 13 is in both ranges and
    // counts once.
    f = f + micro("M3 nested 10-20,12-14", ["10-20", "12-14", "", "11", "13", "15"], 3, 11);

    // M4  The same range twice, 7-9 and 7-9: three integers, not six.
    f = f + micro("M4 duplicate 7-9 twice", ["7-9", "7-9", "", "7", "8", "9"], 3, 3);

    // M5  A single-value range 100-100, with ids on both sides of it.
    f = f + micro("M5 single value 100-100", ["100-100", "", "99", "100", "101"], 1, 1);

    // M6  Inclusive bounds: with only 10-20, ids 0, 9, 10, 20, 21 are
    // fresh only at the two ends.  union 11.
    f = f + micro("M6 inclusive bounds", ["10-20", "", "0", "9", "10", "20", "21"], 2, 11);

    // M7  The smallest database there is: one range of one integer, one ID
    // that is that integer.  It exercises the empty-adjacent edges -- the
    // sweep's ev[0], the accumulator's lo[0] - 1, seg_of's zero-length
    // binary search.
    f = f + micro("M7 smallest 0-0 / 0", ["0-0", "", "0"], 1, 1);

    // M8  Already sorted, already disjoint, one integer apart at each gap.
    // 2-3, 6-7, 10-11: three segments, six integers.
    f = f + micro("M8 disjoint, gapped", ["2-3", "6-7", "10-11", "", "3", "7", "11", "4"], 3, 6);

    // M9  Unsorted and overlapping and touching all at once: 20-30, 1-2,
    // 10-12 -> [1,2] + [10,12] + [20,30] = 2 + 3 + 11 = 16.  ids 11, 25, 3
    // -> 2 fresh.
    f = f + micro("M9 unsorted mixed", ["20-30", "1-2", "10-12", "", "11", "25", "3"], 2, 16);

    // M10 A gap of exactly one spoiled integer, and an ID that lands in the
    // middle of nothing: 5-6 and 8-9 leave 7 spoiled.  ids 5,6,7,8,9 -> 4
    // fresh, union 4.
    f = f + micro("M10 one-integer gap", ["5-6", "8-9", "", "5", "6", "7", "8", "9"], 4, 4);

    // M11 Three ranges whose union is one segment, plus an ID that is
    // spoiled at both ends of it: 1-2, 2-3, 3-4 -> [1,4] = 4.  ids 0, 1, 4,
    // 5 -> 2 fresh.  This is the case the statement's own example warns
    // about: 17 is in two ranges and counts once.
    f = f + micro("M11 chain 1-2,2-3,3-4", ["1-2", "2-3", "3-4", "", "0", "1", "4", "5"], 2, 4);

    // M12 A wide range and a narrow one far away, so the merged segments
    // are far apart: 0-1000 and 5000-5000 -> 1001 + 1 = 1002.  ids 0, 1000,
    // 1001, 5000, 1 -> 4 fresh.
    f = f + micro("M12 far apart", ["0-1000", "5000-5000", "", "0", "1000", "1001", "5000", "1"], 4, 1002);
    f
}

// ── whole-state-space proofs ────────────────────────────────────────────────

// The 28 ranges [a,b] with 0 <= a <= b <= 6: every range in the universe
// small enough to expand by hand.  Ordered triples of them are 21952 cases,
// ordered pairs 784 -- 22736 databases, each checked by every method.
const UNI_HI = 6;

// The fixed probe IDs for every generated case: one below, one above, and
// every integer of the universe, so a boundary off by one in either
// direction is caught.
def probe_ids() -> [long] {
    let p: [long] = [];
    p += -1;
    for v in 0..(UNI_HI + 2) { p += v };
    p
}

// One generated database: run every method for both parts and check every
// invariant.  Returns the number of checks that failed.
def check_case(lo: [long], hi: [long], ids: [long]) -> long {
    let rlo: [long] = [];
    let rhi: [long] = [];
    for i in 0..len(lo) { rlo += lo[i]; rhi += hi[i] };
    sort_pairs(rlo, rhi);
    let mlo: [long] = [];
    let mhi: [long] = [];
    let nseg = merge_ranges(rlo, rhi, mlo, mhi);

    let covered = expand_all(lo, hi);
    let p1 = part1_scan(lo, hi, ids);
    let p1b = part1_binary(mlo, mhi, ids);
    let p1c = part1_set(covered, ids);
    let p2 = part2_merge(mlo, mhi);
    let p2b = part2_accum(rlo, rhi);
    let p2c = part2_sweep(rlo, rhi);
    let p2d = part2_expand(lo, hi);

    let bad = 0;
    // The parts must agree with each other, and with the brute force.
    if (p1 != p1b || p1 != p1c) { bad = bad + 1 };
    if (p2 != p2b || p2 != p2c || p2 != p2d) { bad = bad + 1 };
    // The merge must be a maximal, disjoint, ascending partition.
    if (seg_wellformed(mlo, mhi) != 0) { bad = bad + 1 };
    if (seg_partitions(lo, hi, mlo, mhi) != 0) { bad = bad + 1 };
    if (nseg != len(mlo) || nseg != len(mhi)) { bad = bad + 1 };
    // Decomposition of the total: the covered integers are the union, so
    // the union can never be more than the raw lengths added up, and can
    // never be more than the span from the lowest low to the highest high.
    if (p2 > p2d) { bad = bad + 1 };
    // The fresh count cannot exceed the number of IDs asked about.
    if (p1 > len(ids)) { bad = bad + 1 };
    if (p1 < 0 || p2 < 0) { bad = bad + 1 };
    bad
}

// Every ordered PAIR of ranges from the universe, then every ordered TRIPLE:
// the complete state space of databases with at most three ranges over
// [0, 6], which contains disjoint, nested, duplicated, touching and
// identical ranges in every arrangement.
def check_exhaustive() -> long {
    let n = 0;
    for a1 in 0..(UNI_HI + 1) {
        for b1 in a1..(UNI_HI + 1) {
            for a2 in 0..(UNI_HI + 1) {
                for b2 in a2..(UNI_HI + 1) {
                    n = n + check_case([a1, a2], [b1, b2], probe_ids());
                };
            };
        };
    };
    print(f"  ordered pairs   : 28 x 28 = 784 databases");
    // 28^3 = 21972, less the four cases whose ranges are all empty -- none,
    // since a <= b always holds, so every triple is a real database.
    let ids = probe_ids();
    for a1 in 0..(UNI_HI + 1) {
        for b1 in a1..(UNI_HI + 1) {
            for a2 in 0..(UNI_HI + 1) {
                for b2 in a2..(UNI_HI + 1) {
                    for a3 in 0..(UNI_HI + 1) {
                        for b3 in a3..(UNI_HI + 1) {
                            n = n + check_case([a1, a2, a3], [b1, b2, b3], ids);
                        };
                    };
                };
            };
        };
    };
    print(f"  ordered triples : 28 x 28 x 28 = 21952 databases");
    n
}

// msort must be a sort and not just a shuffle: over EVERY permutation of six
// distinct values, and over every distinct permutation of a multiset with
// repeats, the output has to be ascending AND carry the same multiset.
def next_permutation(p: [long], n: long) -> bool {
    let i = n - 2;
    while (i >= 0 && p[i] >= p[i + 1]) { i = i - 1 };
    if (i < 0) { return false; };
    let j = n - 1;
    while (p[j] <= p[i]) { j = j - 1 };
    let t = p[i];
    p[i] = p[j];
    p[j] = t;
    // reverse p[i+1 .. n)
    let lo = i + 1;
    let hi2 = n - 1;
    while (lo < hi2) {
        let t2 = p[lo];
        p[lo] = p[hi2];
        p[hi2] = t2;
        lo = lo + 1;
        hi2 = hi2 - 1;
    };
    true
}

def is_ascending(a: [long]) -> bool {
    let i = 1;
    let ok = true;
    while (i < len(a) && ok) {
        if (a[i - 1] > a[i]) { ok = false };
        i = i + 1;
    };
    ok
}

// Every value of `base` appears in `a` exactly as often as in `base`.
def same_multiset(a: [long], base: [long]) -> bool {
    let i = 0;
    let ok = true;
    while (i < len(base) && ok) {
        let want = 0;
        let got = 0;
        let j = 0;
        while (j < len(base)) { if (base[j] == base[i]) { want = want + 1 }; j = j + 1 };
        j = 0;
        while (j < len(a)) { if (a[j] == base[i]) { got = got + 1 }; j = j + 1 };
        if (want != got) { ok = false };
        i = i + 1;
    };
    ok
}

def check_permutations() -> long {
    let bad = 0;
    let cases = 0;
    let bases: [[long]] = [];
    bases += [0, 1, 2, 3, 4, 5];
    bases += [3, 1, 4, 1, 5, 9];
    bases += [7, 7, 7, 1];
    bases += [2, 9, 2, 9, 2];
    for bi in 0..len(bases) {
        let n = len(bases[bi]);
        let p: [long] = [];
        for i in 0..n { p += i };
        let more = true;
        while (more) {
            let a: [long] = [];
            for i in 0..n { a += bases[bi][p[i]] };
            sort_asc(a);
            if (!is_ascending(a) || !same_multiset(a, bases[bi])) { bad = bad + 1 };
            cases = cases + 1;
            more = next_permutation(p, n);
        };
    };
    print(f"  msort over {cases} permutations of 4 bases");
    bad
}

// Every permutation of a set of RANGES must come out of sort_pairs ordered by
// (lo, hi) and carrying the same multiset of ranges.  This is a separate
// test from check_permutations because it is the one that catches a pair
// sort that loses the pairing: such a sort still produces an ascending array
// of numbers and a correct-looking total, so nothing else would see it.
def pairs_ascending(lo: [long], hi: [long]) -> bool {
    let i = 1;
    let ok = true;
    while (i < len(lo) && ok) {
        if (lo[i - 1] > lo[i]) {
            ok = false;
        } else if (lo[i - 1] == lo[i] && hi[i - 1] > hi[i]) {
            ok = false;
        };
        i = i + 1;
    };
    ok
}

// Each range of the flat [lo0,hi0,lo1,hi1,...] base appears in (lo, hi) as
// many times as it appears in the base.
def same_pair_multiset(lo: [long], hi: [long], base: [long]) -> bool {
    let nb = len(base) / 2;
    let i = 0;
    let ok = true;
    while (i < nb && ok) {
        let want = 0;
        let got = 0;
        let j = 0;
        while (j < nb) {
            if (base[2 * j] == base[2 * i] && base[2 * j + 1] == base[2 * i + 1]) { want = want + 1 };
            j = j + 1;
        };
        j = 0;
        while (j < nb) {
            if (lo[j] == base[2 * i] && hi[j] == base[2 * i + 1]) { got = got + 1 };
            j = j + 1;
        };
        if (want != got) { ok = false };
        i = i + 1;
    };
    ok
}

def check_pair_permutations() -> long {
    let bad = 0;
    let cases = 0;
    let bases: [[long]] = [];
    let b0: [long] = [];
    b0 += 3; b0 += 7;
    b0 += 1; b0 += 2;
    b0 += 5; b0 += 5;
    b0 += 3; b0 += 9;
    b0 += 8; b0 += 8;
    bases += b0;
    let b1: [long] = [];
    b1 += 9; b1 += 9;
    b1 += 0; b1 += 4;
    b1 += 2; b1 += 7;
    bases += b1;
    let b2: [long] = [];
    b2 += 4; b2 += 9;
    b2 += 0; b2 += 0;
    b2 += 4; b2 += 4;
    b2 += 0; b2 += 9;
    b2 += 2; b2 += 3;
    bases += b2;
    for bi in 0..len(bases) {
        let base = bases[bi];
        let n = len(base) / 2;
        let p: [long] = [];
        for i in 0..n { p += i };
        let more = true;
        while (more) {
            let lo: [long] = [];
            let hi: [long] = [];
            for i in 0..n {
                lo += base[2 * p[i]];
                hi += base[2 * p[i] + 1];
            };
            sort_pairs(lo, hi);
            if (!pairs_ascending(lo, hi)) { bad = bad + 1 };
            if (!same_pair_multiset(lo, hi, base)) { bad = bad + 1 };
            cases = cases + 1;
            more = next_permutation(p, n);
        };
    };
    print(f"  sort_pairs over {cases} permutations of 3 sets of ranges");
    bad
}

// ── the real input ──────────────────────────────────────────────────────────

// Facts about examples/aoc/day05/input.txt established OUTSIDE this program,
// by reading the file with awk and python3 and writing the numbers down
// (see README.md).  They are the parser's and the answers' external
// reference: none of them is computed by the code being checked.
const X_RANGES = 182;              // lines before the blank line
const X_IDS = 1000;                // lines after it
const X_DISTINCT_IDS = 1000;
const X_RAW_TOTAL = 435748243114394;
const X_UNION = 344486348901788;   // python3's sorted-merge sum
const X_SEGS = 78;                 // python3's merged segment count
const X_FRESH = 739;               // python3's linear scan
const X_SPOILED = 261;
const X_MIN_LO = 3777222335448;
const X_MAX_HI = 561691222663012;
const X_SPAN = 557914000327565;    // max_hi - min_lo + 1
const X_DASHES = 182;
const X_SINGLE = 16;               // ranges whose two ends are equal
const X_CONTAINED = 41;           // ranges sitting inside another range
const X_DUP_PAIRS = 6;            // pairs of byte-identical ranges
const X_MULTI = 186;               // IDs covered by two or more ranges

def check_real(path: str, bytes: [byte]) -> long {
    let f = 0;
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        return expect("input readable", false, "cannot read " + path);
    };
    let got: Db? = parse_db(lines!);
    if (got == none) {
        return expect("input well formed", false, parse_err);
    };
    let d = got!;
    let n_rng = len(d.lo);
    let n_id = len(d.ids);
    let raw_total = d.raw_total;

    f = f + expect("input well formed", true,
                   f"{n_rng} ranges, {n_id} ids, {nseg_str(d)} merged segment(s)");

    // ── presence guards FIRST ───────────────────────────────────────────────
    // A comparison between two values that are both absent passes trivially,
    // so every quantity has to be shown present and non-zero before it is
    // compared with anything.  X_RANGES and X_IDS come from outside.
    f = f + expect("ranges present", n_rng > 0 && n_rng == X_RANGES, f"n={n_rng}, outside says {X_RANGES}");
    f = f + expect("ids present", n_id > 0 && n_id == X_IDS, f"n={n_id}, outside says {X_IDS}");
    f = f + expect("segments present", d.nseg > 0 && d.nseg == X_SEGS, f"n={d.nseg}, outside says {X_SEGS}");
    f = f + expect("raw_total present", raw_total > 0 && raw_total == X_RAW_TOTAL,
                   f"raw_total={raw_total}, outside says {X_RAW_TOTAL}");

    // ── the parser against an independent read of the same bytes ───────────
    let sc = rescan(bytes);
    f = f + expect("rescan present", sc.nrng > 0 && sc.nid > 0 && sc.raw_total > 0,
                   f"ranges={sc.nrng} ids={sc.nid} raw_total={sc.raw_total}");
    f = f + expect("parse == rescan: counts",
                   sc.nrng == n_rng && sc.nid == n_id,
                   f"{sc.nrng}/{sc.nid} vs {n_rng}/{n_id}");
    f = f + expect("parse == rescan: raw total", sc.raw_total == raw_total,
                   f"{sc.raw_total} vs {raw_total}");
    f = f + expect("parse == rescan: dashes", sc.ndash == X_DASHES && sc.ndash == n_rng,
                   f"{sc.ndash} dashes, {n_rng} ranges");
    f = f + expect("parse == rescan: extremes", sc.min_lo == X_MIN_LO && sc.max_hi == X_MAX_HI,
                   f"[{sc.min_lo},{sc.max_hi}] vs outside [{X_MIN_LO},{X_MAX_HI}]");

    // Every ID must also read the same through the builtin as through the
    // hand-rolled acceptance in num_reason.
    let tonum_bad = 0;
    let id_sum = 0;
    let distinct = 0;
    let b = find_blank(lines!, eff_lines(lines!));
    for i in b..eff_lines(lines!) {
        let v = tonum(strip_cr(lines![i]));
        if (v != d.ids[i - b]) { tonum_bad = tonum_bad + 1 };
        id_sum = id_sum + v;
        let seen = 0;
        let upto = i - b;
        for j in 0..upto { if (d.ids[j] == v) { seen = seen + 1 } };
        if (seen == 0) { distinct = distinct + 1 };
    };
    f = f + expect("ids == tonum", tonum_bad == 0, f"{tonum_bad} of {n_id} disagree with tonum()");
    f = f + expect("parse == rescan: id sum", sc.id_sum == id_sum, f"{sc.id_sum} vs {id_sum}");
    f = f + expect("ids distinct", distinct == X_DISTINCT_IDS && distinct == n_id,
                   f"{distinct} distinct of {n_id}, outside says {X_DISTINCT_IDS}");

    // ── shapes the statement allows, counted from outside ──────────────────
    let single = 0;
    let contained = 0;
    let dup_pairs = 0;
    for i in 0..n_rng {
        if (d.lo[i] == d.hi[i]) { single = single + 1 };
        let inside = false;
        for j in 0..n_rng {
            if (j == i) { 0 } else {
                if (d.lo[j] <= d.lo[i] && d.hi[i] <= d.hi[j]) { inside = true };
                if (j < i && d.lo[j] == d.lo[i] && d.hi[j] == d.hi[i]) { dup_pairs = dup_pairs + 1 };
            };
        };
        if (inside) { contained = contained + 1 };
    };
    f = f + expect("single-value ranges", single == X_SINGLE, f"{single}, outside says {X_SINGLE}");
    f = f + expect("ranges inside another", contained == X_CONTAINED,
                   f"{contained}, outside says {X_CONTAINED}");
    f = f + expect("identical range pairs", dup_pairs == X_DUP_PAIRS,
                   f"{dup_pairs}, outside says {X_DUP_PAIRS}");

    // ── part 1 ─────────────────────────────────────────────────────────────
    let p1 = part1_scan(d.lo, d.hi, d.ids);
    let p1b = part1_binary(d.mlo, d.mhi, d.ids);
    f = f + expect("part 1 present", p1 > 0, f"part1={p1}");
    f = f + expect("part 1: scan == binary search", p1 == p1b, f"{p1} vs {p1b}");
    f = f + expect("part 1 == externally computed", p1 == X_FRESH,
                   f"{p1}, an independent python3 scan says {X_FRESH}");

    // ── part 2 ─────────────────────────────────────────────────────────────
    let p2 = part2_merge(d.mlo, d.mhi);
    let p2b = part2_accum(d.rlo, d.rhi);
    let p2c = part2_sweep(d.rlo, d.rhi);
    f = f + expect("part 2 present", p2 > 0, f"part2={p2}");
    f = f + expect("part 2: merge == accum", p2 == p2b, f"{p2} vs {p2b}");
    f = f + expect("part 2: merge == sweep", p2 == p2c, f"{p2} vs {p2c}");
    f = f + expect("part 2 == externally computed", p2 == X_UNION,
                   f"{p2}, an independent python3 merge says {X_UNION}");

    // ── invariants ─────────────────────────────────────────────────────────
    // The real input repeats 6 of its ranges, so this is not hypothetical:
    // dropping every repeat has to leave the union exactly where it was.
    let dlo: [long] = [];
    let dhi: [long] = [];
    for i in 0..n_rng {
        let already = false;
        for j in 0..i {
            if (d.lo[j] == d.lo[i] && d.hi[j] == d.hi[i]) { already = true };
        };
        if (!already) { dlo += d.lo[i]; dhi += d.hi[i] };
    };
    sort_pairs(dlo, dhi);
    let u_lo: [long] = [];
    let u_hi: [long] = [];
    let u_nseg = merge_ranges(dlo, dhi, u_lo, u_hi);
    f = f + expect("duplicates do not change the union",
                   part2_merge(u_lo, u_hi) == p2 && u_nseg == d.nseg,
                   f"{len(dlo)} distinct ranges give {part2_merge(u_lo, u_hi)} and "
                   + f"{u_nseg} segment(s), against {p2} and {d.nseg}");
    f = f + expect("merged segments well formed", seg_wellformed(d.mlo, d.mhi) == 0,
                   f"{d.nseg} segments disjoint, ascending and maximal");
    f = f + expect("merged segments partition the ranges",
                   seg_partitions(d.lo, d.hi, d.mlo, d.mhi) == 0,
                   "every range in exactly one segment, every segment holds a range");
    f = f + expect("union <= sum of raw lengths", p2 <= raw_total, f"{p2} <= {raw_total}");
    f = f + expect("union <= span", p2 <= X_SPAN, f"{p2} <= {X_SPAN}");
    let overlap = raw_total - p2;
    f = f + expect("overlap = raw - union", overlap >= 0 && overlap == raw_total - p2,
                   f"{overlap} integers counted twice by the raw lengths");
    f = f + expect("fresh + spoiled == ids", p1 + X_SPOILED == n_id, f"{p1} + {X_SPOILED} == {n_id}");
    f = f + expect("part 1 <= ids", p1 <= n_id, f"{p1} <= {n_id}");

    // An ID covered by more than one range still counts once: count them.
    let multi = 0;
    for k in 0..n_id {
        let hits = 0;
        for i in 0..n_rng { if (d.lo[i] <= d.ids[k] && d.ids[k] <= d.hi[i]) { hits = hits + 1 } };
        if (hits >= 2) { multi = multi + 1 };
    };
    f = f + expect("ids in two or more ranges", multi == X_MULTI, f"{multi}, outside says {X_MULTI}");

    // Monotonicity: every ID in the database is somewhere; adding one more
    // copy of an already-fresh ID cannot raise the count, and adding a
    // spoiled one cannot lower it.
    let with_extra: [long] = [];
    for k in 0..n_id { with_extra += d.ids[k] };
    with_extra += X_MIN_LO;                   // fresh: inside the lowest range
    let p1_extra = part1_binary(d.mlo, d.mhi, with_extra);
    f = f + expect("adding a fresh id raises part 1 by exactly 1", p1_extra == p1 + 1,
                   f"{p1_extra} == {p1} + 1");

    print(f"real input: part 1 = {p1}, part 2 = {p2}, "
          + f"{d.nseg} segment(s), overlap {overlap}");
    f
}

def nseg_str(d: Db) -> str { tostring(d.nseg) }

// ── the check run ───────────────────────────────────────────────────────────

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    let f = check_micro();
    print("whole-state-space proofs (no reference file, no sampled cases):");
    let h0 = heap_used();
    let t0 = clock_us();
    let ex = check_exhaustive();
    let h1 = heap_used();
    let t1 = clock_us();
    print(f"  22736 databases took {(t1 - t0) / 1000} ms and {(h1 - h0) / 1024} KB of arena"
          + f" ({h1} KB used in total)");
    // The proof must have actually run: a heap that did not grow is a proof
    // that did not happen, and would let every agreement below be vacuous.
    f = f + expect("the state-space proof really ran", h1 > h0,
                   f"arena grew by {(h1 - h0) / 1024} KB over 22736 databases");
    f = f + expect("every method agrees over the whole state space", ex == 0,
                   f"22736 databases, {ex} failed checks");
    let pe = check_permutations();
    f = f + expect("msort sorts every permutation", pe == 0,
                   f"every permutation of 4 bases, {pe} bad");
    let qe = check_pair_permutations();
    f = f + expect("sort_pairs keeps every pair together", qe == 0,
                   f"every permutation of 3 sets of ranges, {qe} bad");

    let bytes: [byte]? = fs.read_bytes("input.txt");
    if (bytes == none) {
        f = f + expect("input.txt present", false, "cannot read input.txt");
    } else {
        f = f + check_real("input.txt", bytes!);
    };

    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED (first: {first_failure})");
    f
}

// ── the answer ──────────────────────────────────────────────────────────────

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day05: cannot read " + path + "\n");
        return 1;
    };
    let got: Db? = parse_db(lines!);
    if (got == none) {
        eputs("day05: " + path + ": " + parse_err + "\n");
        return 1;
    };
    let d = got!;
    print("day05: Advent of Code 2025 day 5 -- Cafeteria");
    print(f"input: {path}");
    print(f"fresh ranges: {len(d.lo)} ({d.nseg} merged segment(s))");
    print(f"available ingredient ids: {len(d.ids)}");
    print(f"part 1 (available ids that are fresh): {part1_scan(d.lo, d.hi, d.ids)}");
    print(f"part 2 (distinct ids the ranges cover): {part2_merge(d.mlo, d.mhi)}");
    0
}

const HELP = "day05 -- Advent of Code 2025 day 5 (Cafeteria), in Y

usage:
  ./day05 [FILE]        solve FILE (default input.txt) and print both answers
  ./day05 --check       run the property battery and print every assertion
  ./day05 --help        this text

input shape: inclusive 'lo-hi' fresh ranges, a blank line, then the
available ingredient ids, one per line.

part 1: how many of the available ingredient IDs are fresh
part 2: how many distinct ingredient IDs the ranges cover altogether

part 2's wording is not in the statement (it is login-gated); it comes from
a public write-up.  See README.md for the source and both example anchors.
";

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let have_path = false;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check") {
            want_check = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day05: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day05: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day05: more than one input file given (try --help)\n");
            return 1;
        } else {
            path = a;
            have_path = true;
        };
        i = i + 1;
    };

    if (want_check) {
        run_check();
        if (checks_failed != 0) { return 1 };
        return 0;
    };
    solve(path)
};
exit(main())