// checks.y -- the property check for day02.y, run by `./day02 --check`.
//
// WHY THIS EXISTS.  An AoC answer is a single integer, and a wrong
// algorithm reproduces a wrong integer perfectly: a golden file proves
// determinism and nothing else.  So nothing here compares against
// day02.txt's answer, and nothing reads a reference file.  What it does
// is:
//
//   1. hand-computed micro-cases -- every expected value below was
//      worked out by hand (README.md shows the arithmetic for each one),
//      including the boundary cases a ranges problem is made of: a range
//      of length one, ranges that touch, ranges that overlap, a single
//      EMPTY range, and a value exactly on a boundary;
//   2. an anchor that did not come from this code: part 1 of the
//      statement's own example is 1227775554, published in the puzzle;
//   3. an independent cross-check -- part 1 by three unrelated methods
//      and part 2 by two, on every micro-case AND on the real input;
//   4. invariants the answer must satisfy, including a decomposition
//      (part 2 = part 1 + the IDs whose repeat count is odd, 3 or 5 or
//      7...; and part 2 = the sum over digit lengths);
//   5. guards against a vacuous pass -- every observed value is checked
//      for being PRESENT and non-zero before it is compared, the counts
//      asserted for the real input are counted here by an independent
//      scan of the file's bytes, and the checks are required to be
//      SENSITIVE: deliberately broken variants must FAIL, or the
//      comparison is not evidence of anything.
//
// Exit status is 0 only when every check passes; any failure prints
// FAIL and the program exits 1.  (Traps print to stdout, so a trap here
// would be read as output, not as a failure -- nothing in this file can
// trap: every index is bounded, no division can reach zero, and no
// unwrap of a `none` is reachable.)

import fs;
import ids;

// ── the micro-case table ─────────────────────────────────────────────
//
// Every row is hand-computed in README.md.  `why` is the point of the
// case, not a comment on the code.
type Case = { text: str, p1: long, p2: long, c1: long, c2: long, why: str };

let CASES: [Case] = [
    { text: "11-11", p1: 11, p2: 11, c1: 1, c2: 1,
      why: "a range of length one" },
    { text: "11-22,23-33", p1: 66, p2: 66, c1: 3, c2: 3,
      why: "ranges that TOUCH (22 and 23 are one apart): 11+22+33" },
    { text: "11-22,15-25", p1: 33, p2: 33, c1: 2, c2: 2,
      why: "ranges that OVERLAP: 22 is in both, counted once (55 if not)" },
    { text: "11-22,22-33", p1: 66, p2: 66, c1: 3, c2: 3,
      why: "a shared endpoint" },
    { text: "5-4", p1: 0, p2: 0, c1: 0, c2: 0,
      why: "a single EMPTY range contributes nothing and must not trap" },
    { text: "1010-1010", p1: 1010, p2: 1010, c1: 1, c2: 1,
      why: "a value exactly on a boundary, lo == hi" },
    { text: "123123-123123", p1: 123123, p2: 123123, c1: 1, c2: 1,
      why: "a six-digit doubling, again lo == hi" },
    { text: "111-111", p1: 0, p2: 111, c1: 0, c2: 1,
      why: "odd length: part 2 only (1 three times)" },
    { text: "1111111-1111111", p1: 0, p2: 1111111, c1: 0, c2: 1,
      why: "seven 1s: one repeat, odd length, part 2 only" },
    { text: "999-1001", p1: 0, p2: 999, c1: 0, c2: 1,
      why: "999 is 9 three times; 1000 and 1001 are not periodic" },
    { text: "0101-0101", p1: 0, p2: 0, c1: 0, c2: 0,
      why: "\"0101 is not an ID\": the number is 101, which is VALID" },
    { text: "1001-1111", p1: 2121, p2: 2121, c1: 2, c2: 2,
      why: "1010 and 1111; 1111 is 11 twice AND 1 four times, once only" },
    { text: "99-999", p1: 99, p2: 5094, c1: 1, c2: 10,
      why: "99 on the boundary, then 111..999" },
    { text: "48-48", p1: 0, p2: 0, c1: 0, c2: 0,
      why: "a VALID ID alone: the answer is 0, and a check that passed"
            + " here would pass on nothing at all" },
    { text: "1-1000", p1: 495, p2: 5490, c1: 9, c2: 18,
      why: "fully hand-derived: 11*(1+..+9)=495, +111*(1+..+9)=5490" },
    { text: "1212-1212,121-1212", p1: 3333, p2: 8217, c1: 3, c2: 11,
      why: "1212 is in BOTH ranges and is counted once" }
];

// The statement's own example, kept in the wrapped form the puzzle page
// uses (the parser is whitespace-tolerant on purpose) with its published
// part-1 answer and the part-2 answer derived by hand in README.md.
const EXAMPLE: str = "11-22,95-115,998-1012,1188511880-1188511890,222220-222224,\n"
    + "1698522-1698528,446443-446449,38593856-38593862,565653-565659,\n"
    + "824824821-824824827,2121212118-2121212124";
const EXAMPLE_P1: long = 1227775554;      // published by the puzzle
const EXAMPLE_P2: long = 4174379265;      // 1227775554 + 111+999+565656+824824824+2121212121
const EXAMPLE_C1: long = 8;
const EXAMPLE_C2: long = 13;

// The real input's small ranges, hand-read from day02.txt and NOT
// computed by the solver: the only 2-digit invalid ID in any range is in
// "1-16" (11) or in "25-110" (33..99), and the only 3-digit ones are in
// "171-671" (222..666).  Those two rows are external anchors inside the
// real-input section.
const ANCHOR_2D_N: long = 8;             // 11,33,44,55,66,77,88,99
const ANCHOR_2D_SUM: long = 473;         // 11+33+44+55+66+77+88+99
const ANCHOR_3D_N: long = 5;             // 222,333,444,555,666
const ANCHOR_3D_SUM: long = 2220;        // 222+333+444+555+666
const INPUT_MAXDIG: long = 10;           // the largest ID in the input, 9696996784

// The widest input this will brute-force element by element.  The
// property check REQUIRES the real input to be under it, so that the
// cross-check below can never quietly skip itself.
const BRUTE_MAX: long = 4000000;

let passes: long = 0;
let fails: long = 0;

def ok(name: str, cond: bool, detail: str) -> void {
    if (cond) {
        passes = passes + 1;
        print("  [ok]   " + name + (if detail == "" { "" } else { "  " + detail }))
    } else {
        fails = fails + 1;
        print("  [FAIL] " + name + (if detail == "" { "" } else { "  " + detail }))
    }
};

// pair(a, b) -> str -- "53420042388 vs 53420042387" for a failure line.
def pair(a: long, b: long) -> str { tostring(a) + " vs " + tostring(b) };

// ── independent scans of the raw file ────────────────────────────────
//
// The parser walks the text with a state machine; these count the bytes.
// A parser that dropped the last field, or merged two fields, or read a
// range backwards, cannot agree with them.
def count_byte(text: str, b: long) -> long {
    let n = 0;
    let i = 0;
    let n2 = text.length;
    while (i < n2) {
        if (text[i] == b) { n = n + 1 };
        i = i + 1
    };
    n
};

def scan_sound(text: str, spans: [ids.Span]) -> bool {
    // commas + 1 fields, one dash per field, every field non-empty and
    // non-inverted
    if (count_byte(text, 44) + 1 != len(spans)) { return false };
    if (count_byte(text, 45) != len(spans)) { return false };
    let i = 0;
    while (i < len(spans)) {
        if (spans[i].lo > 0 && spans[i].lo <= spans[i].hi) { i = i + 1 } else { return false }
    };
    true
};

// ── micro-cases ──────────────────────────────────────────────────────
//
// Five numbers per case, from five code paths: part 1 by the
// element-by-element brute force, by the arithmetic progression walk, and
// by the generator's even-repeat bucket; part 2 by the brute force and by
// the generator.  The row passes only if all five equal the
// hand-computed table.
//
// Every case goes through ids.solve -- the same entry point ./day02 uses
// -- so a defect in the pipeline cannot hide from the check by living in
// one of its callers.  (The first version had each caller assemble the
// pipeline itself from the same pieces; a defect in day02.y's use of
// merge() was then invisible to the check, which merged correctly and
// agreed with itself, 61 checks green, on a solver that double-counts
// every overlapping range.)
def case_agrees(c: Case, a: ids.Answer) -> bool {
    let w = ids.ap_walk(a.merged);
    if (a.part1.sum != c.p1 || a.part1.count != c.c1) { return false };
    if (w.sum != c.p1 || w.count != c.c1) { return false };
    if (a.g.tw != c.p1 || a.g.twc != c.c1) { return false };
    if (a.part2.sum != c.p2 || a.part2.count != c.c2) { return false };
    if (a.g.sum != c.p2 || a.g.count != c.c2) { return false };
    true
};

// why_case(c, a) -> str -- what the methods actually said, for a failing
// row.  Naming the methods matters: "expected X, got Y" without saying
// which of them disagreed is not a diagnostic.
def why_case(c: Case, a: ids.Answer) -> str {
    let w = ids.ap_walk(a.merged);
    "want p1 " + tostring(c.p1) + "/" + tostring(c.c1)
    + " p2 " + tostring(c.p2) + "/" + tostring(c.c2)
    + "; brute p1 " + tostring(a.part1.sum) + "/" + tostring(a.part1.count)
    + ", walk p1 " + tostring(w.sum) + "/" + tostring(w.count)
    + ", gen p1 " + tostring(a.g.tw) + "/" + tostring(a.g.twc)
    + ", brute p2 " + tostring(a.part2.sum) + "/" + tostring(a.part2.count)
    + ", gen p2 " + tostring(a.g.sum) + "/" + tostring(a.g.count)
};

def case_line(c: Case) -> str {
    "  " + c.why + "\n"
    + "      input " + c.text + "\n"
    + "      part 1  sum " + tostring(c.p1) + " over " + tostring(c.c1) + " IDs"
    + "   part 2  sum " + tostring(c.p2) + " over " + tostring(c.c2) + " IDs\n"
};

def run_micro() -> void {
    print("\n1. micro-cases, hand-computed (README.md has the arithmetic)");
    let i = 0;
    while (i < len(CASES)) {
        let c = CASES[i];
        i = i + 1;
        let a = ids.solve(c.text, true);
        if (a.ok == false) {
            ok(c.text + " solves", false, a.msg)
        } else {
            let good = case_agrees(c, a);
            let detail = "p1 " + tostring(c.p1) + "/" + tostring(c.c1)
                       + "  p2 " + tostring(c.p2) + "/" + tostring(c.c2);
            if (good == false) { detail = why_case(c, a) };
            print(case_line(c));
            ok(c.text, good, detail)
        }
    }
};

// The statement's example: part 1's answer was published by the puzzle,
// so it is the one number here that this code did not produce.
def run_example() -> void {
    print("\n2. the statement's own example (part 1's answer is published: 1227775554)");
    let a = ids.solve(EXAMPLE, true);
    ok("example solves", a.ok, a.msg);
    ok("example: 11 fields, 11 dashes",
       scan_sound(EXAMPLE, a.raw), tostring(len(a.raw)) + " ranges");
    let w = ids.ap_walk(a.merged);
    ok("example part 1 == 1227775554 by brute force",
       a.part1.sum == EXAMPLE_P1 && a.part1.count == EXAMPLE_C1,
       pair(a.part1.sum, EXAMPLE_P1) + " over " + pair(a.part1.count, EXAMPLE_C1) + " IDs");
    ok("example part 1 == 1227775554 by the progression walk",
       w.sum == EXAMPLE_P1 && w.count == EXAMPLE_C1, pair(w.sum, EXAMPLE_P1));
    ok("example part 1 == 1227775554 by the generator",
       a.g.tw == EXAMPLE_P1 && a.g.twc == EXAMPLE_C1, pair(a.g.tw, EXAMPLE_P1));
    ok("example part 2 == 4174379265 (hand-derived) by brute force",
       a.part2.sum == EXAMPLE_P2 && a.part2.count == EXAMPLE_C2,
       pair(a.part2.sum, EXAMPLE_P2));
    ok("example part 2 == 4174379265 by the generator",
       a.g.sum == EXAMPLE_P2 && a.g.count == EXAMPLE_C2, pair(a.g.sum, EXAMPLE_P2));
    ok("example: part 2 == part 1 + the IDs with an ODD repeat count",
       a.g.tw + a.g.th == a.g.sum && a.g.twc + a.g.thc == a.g.count,
       pair(a.g.tw + a.g.th, a.g.sum) + ", " + pair(a.g.twc + a.g.thc, a.g.count));
    let fast = ids.solve(EXAMPLE, false);
    ok("example: the fast path and the element-by-element path agree",
       fast.part1.sum == a.part1.sum && fast.part2.sum == a.part2.sum
       && fast.part1.count == a.part1.count && fast.part2.count == a.part2.count,
       pair(fast.part1.sum, a.part1.sum) + ", " + pair(fast.part2.sum, a.part2.sum));
};

// ── the real input ───────────────────────────────────────────────────
def run_real(path: str, text: str) -> void {
    print("\n3. the real input, " + path);
    let a = ids.solve(text, true);
    ok("the input solves", a.ok, a.msg);
    let raw = a.raw;
    let m = a.merged;
    let g = a.g;
    let b1 = a.part1;
    let b2 = a.part2;
    let total = a.total;
    let empty = a.empties;
    ok("byte scan agrees with the parser (commas + 1 = fields, one dash each)",
       scan_sound(text, raw), tostring(count_byte(text, 44)) + " commas, "
       + tostring(len(raw)) + " ranges, " + tostring(count_byte(text, 45)) + " dashes");
    ok("merged spans are disjoint (nothing is counted twice)",
       ids.disjoint(m), tostring(len(m)) + " spans");
    ok("the union is non-empty", total > 0, tostring(total) + " IDs in the union");
    ok("merging never grows the union",
       total <= ids.span_total(raw),
       tostring(ids.span_total(raw)) + " -> " + tostring(total)
       + (if empty > 0 { " (" + tostring(empty) + " empty range(s) dropped)" } else { "" }));

    // the fast path is what ./day02 prints, so it is checked too, against
    // the same input, rather than assumed to agree
    let fast = ids.solve(text, false);
    ok("the fast path and the element-by-element path agree on part 1",
       fast.part1.sum == b1.sum && fast.part1.count == b1.count,
       pair(fast.part1.sum, b1.sum) + " over " + pair(fast.part1.count, b1.count) + " IDs");
    ok("and on part 2",
       fast.part2.sum == b2.sum && fast.part2.count == b2.count,
       pair(fast.part2.sum, b2.sum) + " over " + pair(fast.part2.count, b2.count) + " IDs");

    // -- non-vacuity FIRST: every one of these is asserted PRESENT and
    // non-zero before it is compared with anything, because a check
    // that compares two absent values passes (and two agents in this
    // campaign shipped exactly that).
    ok("the brute force really looked at every ID",
       total > 0 && total <= BRUTE_MAX,
       tostring(total) + " IDs <= " + tostring(BRUTE_MAX) + " limit");
    let w = ids.ap_walk(m);
    ok("brute force examined the whole union", b1.seen == total, pair(b1.seen, total));
    ok("brute force examined the whole union (part 2)", b2.seen == total, pair(b2.seen, total));
    ok("the generator found IDs (got, not a default)", g.got == 1, pair(g.got, 1));
    ok("part 1 found a non-zero number of IDs",
       b1.count > 0 && w.count > 0 && g.twc > 0,
       "brute " + tostring(b1.count) + ", walk " + tostring(w.count)
       + ", gen " + tostring(g.twc));
    ok("part 2 found a non-zero number of IDs",
       b2.count > 0 && g.count > 0, "brute " + tostring(b2.count) + ", gen " + tostring(g.count));
    ok("the generator and the brute force walked different domains, as designed",
       g.cand < b2.seen, tostring(g.cand) + " candidate blocks vs " + tostring(b2.seen) + " IDs");

    // -- the cross-check: part 1 three ways, part 2 two ways.
    ok("part 1: brute force == the progression walk",
       b1.sum == w.sum && b1.count == w.count,
       pair(b1.sum, w.sum) + " over " + pair(b1.count, w.count) + " IDs");
    ok("part 1: brute force == the generator's even-repeat bucket",
       b1.sum == g.tw && b1.count == g.twc,
       pair(b1.sum, g.tw) + " over " + pair(b1.count, g.twc) + " IDs");
    ok("part 2: brute force == the generator",
       b2.sum == g.sum && b2.count == g.count,
       pair(b2.sum, g.sum) + " over " + pair(b2.count, g.count) + " IDs");
    print("      part 1 answer " + tostring(b1.sum) + " over " + tostring(b1.count) + " IDs");
    print("      part 2 answer " + tostring(b2.sum) + " over " + tostring(b2.count) + " IDs");

    // -- invariants the answer must satisfy.
    ok("part 2 == part 1 + the IDs with an ODD repeat count (sums)",
       g.tw + g.th == g.sum, pair(g.tw + g.th, g.sum));
    ok("part 2 == part 1 + the IDs with an ODD repeat count (counts)",
       g.twc + g.thc == g.count, pair(g.twc + g.thc, g.count));
    ok("part 1 is a subset of part 2, so it cannot be the larger sum",
       g.tw <= g.sum && g.twc <= g.count, pair(g.tw, g.sum));
    ok("some ID in this input has an ODD repeat count (3, 5, 7...)",
       g.thc > 0 && g.th > 0, tostring(g.thc) + " IDs summing to " + tostring(g.th));
    ok("no ID is counted more often than the union contains IDs",
       g.count <= total && g.count >= 0, tostring(g.count) + " <= " + tostring(total));

    // -- the decomposition into digit lengths: the parts must sum to the
    // whole, and there must be more than one non-empty row (a table of
    // zeros would also "sum" correctly).
    let lsum: long = 0;
    let lcnt: long = 0;
    let lens: long = 0;
    let maxlen: long = 0;
    let l = 2;
    while (l <= ids.MAXDIG) {
        if (g.perlen_n[l] > 0) {
            lens = lens + 1;
            lsum = lsum + g.perlen[l];
            lcnt = lcnt + g.perlen_n[l];
            if (l > maxlen) { maxlen = l }
        };
        l = l + 1
    };
    ok("the per-digit-length table sums to the part 2 answer",
       lsum == g.sum, pair(lsum, g.sum));
    ok("the per-digit-length counts sum to the part 2 count",
       lcnt == g.count, pair(lcnt, g.count));
    ok("the table has more than one non-empty row and stops at the input's widest ID",
       lens > 1 && maxlen == INPUT_MAXDIG,
       tostring(lens) + " rows, widest " + tostring(maxlen) + " digits");

    // -- two rows of that table, hand-read from day02.txt rather than
    // computed here: the 2- and 3-digit invalid IDs are all in "1-16",
    // "25-110" and "171-671", and they can be listed by eye.
    ok("the 2-digit row is the 8 hand-read IDs in 1-16 and 25-110",
       g.perlen_n[2] == ANCHOR_2D_N && g.perlen[2] == ANCHOR_2D_SUM,
       tostring(g.perlen_n[2]) + " IDs / " + tostring(g.perlen[2])
       + " (want " + tostring(ANCHOR_2D_N) + " / " + tostring(ANCHOR_2D_SUM) + ")");
    ok("the 3-digit row is the 5 hand-read IDs in 171-671",
       g.perlen_n[3] == ANCHOR_3D_N && g.perlen[3] == ANCHOR_3D_SUM,
       tostring(g.perlen_n[3]) + " IDs / " + tostring(g.perlen[3])
       + " (want " + tostring(ANCHOR_3D_N) + " / " + tostring(ANCHOR_3D_SUM) + ")");

    // -- every emitted ID lies inside the union of the ranges, checked by
    // membership rather than by comparing bounds.
    let lo_id = first_lo(m);
    let hi_id = last_hi(m);
    ok("the smallest and largest emitted ID are inside the union",
       inside(m, g.lo) && inside(m, g.hi),
       tostring(g.lo) + " and " + tostring(g.hi) + " within ["
       + tostring(lo_id) + ", " + tostring(hi_id) + "]");
    ok("the emitted range is inside the input's range of values",
       g.lo >= lo_id && g.hi <= hi_id, pair(g.lo, lo_id) + " " + pair(g.hi, hi_id));

    // -- sensitivity at a BOUNDARY, which is where a ranges solver goes
    // wrong.  A 1010-wide span is used here on purpose: the largest ID in
    // the file cannot be probed this way, because the brute force would
    // have to walk ten billion values to reach it.
    //
    // (The first version of this check widened the union past the largest
    // ID in the FILE -- 9696996785, a VALID ID -- so nothing changed and
    // the check correctly failed.  A perturbation that moves no ID cannot
    // prove an equality is sensitive.)
    let edge: [ids.Span] = [];
    edge += { lo: 1, hi: 1010 };
    let below: [ids.Span] = [];
    below += { lo: 1, hi: 1009 };
    let ebase = ids.gen(edge);
    let ecut = ids.gen(below);
    ok("an ID exactly on the range end is counted: dropping it changes the sum by exactly it",
       ebase.sum - ecut.sum == 1010 && ebase.count - ecut.count == 1
       && ebase.sum > ecut.sum && ecut.sum > 0,
       tostring(ebase.sum) + " - " + tostring(ecut.sum) + " = 1010"
       + ", " + tostring(ebase.count) + " - " + tostring(ecut.count) + " = 1 ID");
    let wbase = ids.ap_walk(edge);
    let wcut = ids.ap_walk(below);
    ok("and the progression walk agrees about that boundary too",
       wbase.sum - wcut.sum == 1010 && wbase.count - wcut.count == 1,
       tostring(wbase.sum) + " - " + tostring(wcut.sum) + " = 1010");
    let bebase = ids.brute(edge, 2);
    let becut = ids.brute(below, 2);
    ok("and so does the brute force",
       bebase.sum - becut.sum == 1010, pair(bebase.sum, becut.sum));

    // -- additivity over disjoint spans: cutting the union in half must
    // not change the answer, for either part and by either method.  This
    // is the decomposition an overlapping or un-merged range breaks.
    let cut = len(m) / 2;
    let head: [ids.Span] = [];
    let tail: [ids.Span] = [];
    let k = 0;
    while (k < len(m)) {
        if (k < cut) { head += { lo: m[k].lo, hi: m[k].hi } }
        else { tail += { lo: m[k].lo, hi: m[k].hi } };
        k = k + 1
    };
    let gh = ids.gen(head);
    let gt = ids.gen(tail);
    let bh1 = ids.brute(head, 1);
    let bt1 = ids.brute(tail, 1);
    let bh2 = ids.brute(head, 2);
    let bt2 = ids.brute(tail, 2);
    ok("the two halves of the union sum to the whole, part 2 (generator)",
       gh.sum + gt.sum == g.sum && gh.count + gt.count == g.count,
       pair(gh.sum + gt.sum, g.sum));
    ok("and part 2 (brute force)",
       bh2.sum + bt2.sum == b2.sum && bh2.count + bt2.count == b2.count,
       pair(bh2.sum + bt2.sum, b2.sum));
    ok("and part 1 (generator and brute force)",
       gh.tw + gt.tw == g.tw && bh1.sum + bt1.sum == b1.sum,
       pair(gh.tw + gt.tw, g.tw) + ", " + pair(bh1.sum + bt1.sum, b1.sum));

    // -- a deliberately WRONG expectation must fail: this is the check
    // that the harness itself is not a no-op.  Row 14 is "1-1000", the
    // one whose arithmetic is spelled out in full in README.md.
    let c0 = CASES[14];
    let wrong: Case = { text: c0.text, p1: c0.p1 + 1, p2: c0.p2, c1: c0.c1, c2: c0.c2,
                        why: "" };
    let wa = ids.solve(wrong.text, true);
    ok("a deliberately wrong expectation is REJECTED",
       case_agrees(wrong, wa) == false,
       "claiming " + tostring(wrong.p1) + " for " + wrong.text + " must not pass");
    ok("the un-wronged expectation is accepted",
       case_agrees(c0, wa), "so the rejection above is the table's doing");
};

def inside(m: [ids.Span], n: long) -> bool {
    let i = 0;
    let hit = false;
    while (i < len(m) && hit == false) {
        if (n >= m[i].lo && n <= m[i].hi) { hit = true };
        i = i + 1
    };
    hit
};

def first_lo(m: [ids.Span]) -> long {
    let i = 0;
    let v = 0;
    while (i < len(m)) {
        if (i == 0 || m[i].lo < v) { v = m[i].lo };
        i = i + 1
    };
    v
};

def last_hi(m: [ids.Span]) -> long {
    let i = 0;
    let v = 0;
    while (i < len(m)) {
        if (m[i].hi > v) { v = m[i].hi };
        i = i + 1
    };
    v
};

def read_or_quit(path: str) -> str {
    let got = fs.read_file(path);
    if (is_some(got)) { return unwrap(got) };
    print("day02: cannot read " + path);
    ""
};

// run(path, timing) -> long -- the --check entry point.
def run(path: str, timing: bool) -> long {
    let t0 = clock_us();
    print("day02 --check: property checks for the Gift Shop solver");
    print("  (no reference file is read; every expectation is hand-derived");
    print("   in README.md or counted here by an independent byte scan)");
    let text = read_or_quit(path);
    if (text == "") { return 1 };
    run_micro();
    run_example();
    run_real(path, text);
    print("\n4. sensitivity: the checks must be able to fail on demand");
    // The table has 16 rows; a row silently dropped would show up here.
    ok("the micro-case table has all 16 rows and none is empty",
       len(CASES) == 16 && CASES[0].text == "11-11" && CASES[15].text != "",
       tostring(len(CASES)) + " rows, first " + CASES[0].text + ", last " + CASES[15].text);
    let nz: long = 0;
    let z: long = 0;
    let j = 0;
    while (j < len(CASES)) {
        if (CASES[j].p1 > 0 || CASES[j].p2 > 0) { nz = nz + 1 } else { z = z + 1 };
        j = j + 1
    };
    ok("the table has both zero-answer rows and non-zero rows, so the zeros are not all of it",
       nz >= 8 && z >= 2, tostring(nz) + " non-zero, " + tostring(z) + " zero");
    print("\n" + tostring(passes) + " checks passed, " + tostring(fails) + " failed");
    if (timing) {
        print("  time     : " + tostring((clock_us() - t0) / 1000) + " ms")
    };
    if (fails > 0) {
        print("day02: the property check FAILED");
        return 1
    };
    print("day02: the property check passed");
    0
};