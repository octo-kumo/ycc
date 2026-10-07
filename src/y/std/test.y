// test -- assertions, so no program writes its own.
//
// WHY THIS IS A std MODULE.  Eight of the thirty-nine examples in examples/
// defined their own `ck`, and the same name meant four different things:
//
//   def ck(cond: bool, what: str) -> bool             sandfall
//   def ck(got: long, want: long, what: str) -> bool   hexview
//   def ck(name: str, ok: bool, detail: str)           audio, x11
//   def ck(name: str, ok: bool, detail: str) -> void   wavefunction
//
// The second of those is not an assertion at all but an equality check wearing
// the name, so `ck(a, b, "name")` is an equality test there and a truthiness
// test everywhere else -- with no type error to stop it.  `ck_eq` had the same
// split over `-> long` versus `-> void`.  Five folders also each printed their
// own "N of M passed" line in a different format, which is why a reader cannot
// tell whether a green folder ran 41 assertions or 720.
//
// The public surface is nine functions:
//
//   ck(name, ok, detail)     ck_eq(name, got, want)
//   ck_near(name, got, want, tol)    ck_str(name, got, want)
//   ck_bytes(name, got, want)
//   group(name)   checks()   failures()   report()
//
// `ck_str` and `ck_bytes` are separate functions rather than one generic
// `ck_eq` because there are no generics: a `[byte]` is not a `long`, so one
// signature cannot cover both.
//
// EVERY assertion prints a DETAIL line on both outcomes, not just on failure.
// That is what audio/check.y does and it is why its failures were diagnosable
// without a rerun: a FAIL states what was measured and what was wanted.
//
// Output goes to STDOUT, like `print`.  Call `group()` to make a run readable.

let n_checks: long = 0;
let n_failed: long = 0;

// group(name) -- a labelled section.  A blank line first, so the sections read
// as sections rather than as one undifferentiated list of lines.
def group(name: str) {
    print("");
    print(name);
};

// ck(name, ok, detail) -> bool -- the one assertion.
//
// Returns whether it PASSED, not whether it failed, so a caller can write
// `if (!ck(...)) { ... }` and mean what it says.  `detail` is printed on both
// outcomes: on a pass it is the measurement, on a fail it is the measurement
// beside the expectation.
def ck(name: str, ok: bool, detail: str) -> bool {
    n_checks = n_checks + 1;
    if (ok) {
        print("  ok    " + name);
        if (detail != "") { print("          " + detail); };
    } else {
        n_failed = n_failed + 1;
        print("  FAIL  " + name);
        print("          " + detail);
    };
    ok
};

// ck_eq(name, got, want) -> bool
def ck_eq(name: str, got: long, want: long) -> bool {
    ck(name, got == want, "got " + tostring(got) + ", want " + tostring(want))
};

// ck_near(name, got, want, tol) -> bool -- for a quantity with a tolerance,
// which is almost every measured one: an RMS, a throughput, a pixel count.
def ck_near(name: str, got: long, want: long, tol: long) -> bool {
    let d = got - want;
    if (d < 0) { d = 0 - d };
    ck(name, d <= tol, "got " + tostring(got) + ", want " + tostring(want)
        + " +/- " + tostring(tol) + " (off by " + tostring(d) + ")")
};

// ck_str(name, got, want) -> bool
//
// The detail line is a SUMMARY on a pass and the whole value on a fail.  The
// first version printed both values always, which is fine for "abc" and
// useless for a pretty-printed JSON document: a passing comparison printed two
// identical forty-line blobs and buried the line under them.
def ck_str(name: str, got: str, want: str) -> bool {
    let same = got == want;
    if same {
        ck(name, true, tostring(got.length) + " chars")
    } else {
        ck(name, false, "got " + got + ", want " + want)
    }
};

// ck_bytes(name, got, want) -> bool -- a `[byte]`, which `ck_eq` cannot take.
def ck_bytes(name: str, got: [byte], want: [byte]) -> bool {
    let same = got == want;
    let detail = tostring(got.length) + " B, want " + tostring(want.length) + " B";
    if (!same) {
        // The shared prefix, and then the first byte that differs -- but only
        // while BOTH arrays still have a byte there. Reporting the difference
        // is the whole point of this function, so it must not trap doing it:
        // the first version indexed got[i] and want[i] after the loop without
        // asking whether i was inside the shorter array, so ck_bytes("four
        // ones", four, three) died with "index out of bounds" instead of
        // reporting that one is a byte longer. Its own test found it.
        let i = 0;
        while (i < got.length && i < want.length && got[i] == want[i]) { i = i + 1 };
        if (i >= got.length) {
            detail = detail + "; want is " + tostring(want.length - i)
            + " byte(s) longer";
        } else {
            if (i >= want.length) {
                detail = detail + "; got is " + tostring(got.length - i)
                + " byte(s) longer";
            } else {
                detail = detail + "; first difference at byte " + tostring(i)
                + ": got " + tostring(got[i]) + ", want " + tostring(want[i])
            }
        }
    };
    ck(name, same, detail)
};

def checks() -> long { n_checks };
def failures() -> long { n_failed };

// report() -> long -- "N of M checks passed"; 0 if all passed, 1 otherwise.
// The return value is what a `check=` command exits on.
def report() -> long {
    print("");
    print(tostring(n_checks - n_failed) + " of " + tostring(n_checks)
        + " checks passed");
    if (n_failed > 0) { 1 } else { 0 }
};

export { group, ck, ck_eq, ck_near, ck_str, ck_bytes,
    checks, failures, report };
