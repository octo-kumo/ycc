// std/test: the harness itself. A checking library that is never checked is a
// library whose failures are indistinguishable from its successes, so this file
// drives it and asserts on what it prints.
//
// The output is compared against a .expected, which makes the printed form of a
// failure part of the contract: the detail line, the "got/want" wording, the
// group heading, and the summary line all have to be what they claim.
//
// This file DELIBERATELY fails checks -- a harness tested only on its happy path
// is untested. It therefore compares every count as a DELTA from a baseline
// taken at the start, and never asserts an absolute failure count, because the
// failures it causes are the point. It exits 1, and the .expected says so.
import test;

def main() -> long {
    // Baseline. Both counters are module state a program may already have used
    // before importing the harness, so nothing below is written as an absolute.
    let f0 = test.failures();

    // ─────────────────────────────────────────── the counters
    // A baseline is read IMMEDIATELY before the one check whose increment is
    // about to be measured. Reading it earlier and asserting a delta of 1 does
    // not work, because the assertion itself is a check and has already counted.
    test.group("the counters");
    test.ck("nothing has failed yet", test.failures() == f0,
        "the baseline is the starting point");

    let c0 = test.checks();
    test.ck("a passing check", true, "and it counts");
    test.ck_eq("so exactly one more check has run", test.checks() - c0, 1);
    test.ck_eq("and no more failures", test.failures() - f0, 0);

    // this one is nested: the inner ck_eq is itself a check, so TWO count
    let c1 = test.checks();
    test.ck("ck_eq on equal longs passes", test.ck_eq("two longs", 5, 5),
        "and it counts as a check");
    test.ck_eq("so the pair counted twice", test.checks() - c1, 2);
    test.ck_eq("and still no failures", test.failures() - f0, 0);

    // ─────────────────────────────────────────── ck_near
    test.group("ck_near is ck_eq with a tolerance");
    let f1 = test.failures();
    test.ck("inside the tolerance passes",
        test.ck_near("measured", 100, 103, 5), "3 off, 5 allowed");
    test.ck_eq("and did not fail", test.failures() - f1, 0);
    test.ck("outside it fails",
        !test.ck_near("measured", 100, 110, 5), "10 off, 5 allowed");
    test.ck_eq("and counted one failure", test.failures() - f1, 1);
    test.ck("a tolerance of 0 is exactness",
        test.ck_near("exact", 42, 42, 0), "0 off, 0 allowed");
    test.ck("and one off fails it",
        !test.ck_near("exact", 42, 43, 0), "1 off, 0 allowed");
    test.ck_eq("two failures so far in this group", test.failures() - f1, 2);

    // ─────────────────────────────────────────── ck_str
    test.group("ck_str");
    let f2 = test.failures();
    test.ck("equal strings pass",
        test.ck_str("a string", "abc", "abc"), "3 chars");
    test.ck("unequal strings fail",
        !test.ck_str("a string", "abc", "abd"), "abc against abd");
    test.ck("an empty string is a string",
        test.ck_str("empty", "", ""), "0 chars");
    test.ck("and differs from a space",
        !test.ck_str("empty", "", " "), "so it is not treated as absent");
    test.ck_eq("two failures in this group too", test.failures() - f2, 2);

    // ─────────────────────────────────────────── ck_bytes
    test.group("ck_bytes");
    let f3 = test.failures();
    let b1: [byte] = [1; 4];
    let b2: [byte] = [1; 4];
    let b3: [byte] = [1; 3];
    let b4: [byte] = [1; 4];
    b4[3] = 2;
    test.ck("equal byte arrays pass",
        test.ck_bytes("four ones", b1, b2), "byte for byte");
    test.ck("a different length fails",
        !test.ck_bytes("four ones", b1, b3), "4 B against 3 B");
    test.ck("the same length with one byte changed fails",
        !test.ck_bytes("four ones", b1, b4), "the last byte differs");
    test.ck_eq("two failures in this group", test.failures() - f3, 2);
    let e1: [byte] = [];
    let e2: [byte] = [];
    test.ck("two empty arrays are equal",
        test.ck_bytes("empties", e1, e2), "so an absent result can be compared");

    // ck_bytes reporting a length difference must not run off the end of the
    // shorter array. It used to, which is a trap in the middle of a report.
    let four: [byte] = [7; 4];
    let two: [byte] = [7; 2];
    let g1 = test.failures();
    test.ck("ck_bytes on a shorter WANT does not trap",
        !test.ck_bytes("four against two", four, two),
        "reports that want is longer");
    test.ck("nor on a shorter GOT",
        !test.ck_bytes("two against four", two, four),
        "reports that got is longer");
    test.ck_eq("and both were reported, not fatal", test.failures() - g1, 2);

    // ─────────────────────────────────────────── ck's detail argument
    // A choice, not an accident: a check that PASSES still prints its detail, so
    // a detail phrased as a failure hint reads oddly on success. It is what makes
    // a passing run self-describing, and it is why both lines below appear in the
    // .expected. The failing one is the ninth and last deliberate failure in this
    // file.
    test.group("ck's detail is printed either way");
    test.ck("a passing check still prints its detail", true,
        "this line appears under an ok");
    test.ck("a failing one prints it too", false,
        "and this line appears under a FAIL");

    // ─────────────────────────────────────────── group
    test.group("group() names the section that follows");
    test.ck("a check inside a named group", true, "reported under that name");

    // ─────────────────────────────────────────── report
    test.group("report");
    test.ck("the run has failures to report", test.failures() > f0,
        "nine checks on purpose, so the FAIL path is visible");
    test.ck("and more passes than failures",
        (test.checks() - f0) > (test.failures() - f0), "and the rest passed");
    test.ck("report() answers 1 when anything failed", test.report() == 1,
        "not the count -- so a caller can hand it straight to exit()");
    test.ck("and the counts are unchanged by reporting",
        test.checks() > f0 + 1 && test.failures() > f0,
        "reporting reads, it does not reset");

    return test.report();
};
exit(main());
