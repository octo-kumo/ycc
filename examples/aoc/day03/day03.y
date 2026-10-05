// day03.y -- Advent of Code 2025, day 3 ("Lobby"), in Y.
//
// Each line of the input is a *bank* of batteries, each labelled with a
// joltage rating 1..9.  From a bank you turn on exactly k of them, keeping
// their order -- "you cannot rearrange batteries" -- and the bank produces
// the number spelled by those k digits.  Each bank contributes its largest
// possible number, and the answer is the sum over banks.
//
//   part 1   k = 2       (the statement, authoritative)
//   part 2   k = 12      (NOT from AoC: part 2 of every 2025 puzzle is behind
//                        a login.  Taken from a public write-up; README.md
//                        gives the source URL and the two example values
//                        that anchor the reading.)
//
// One engine answers both parts; only k changes.  Four independent
// implementations of it exist here and --check holds them against each other
// and against an exhaustive brute force:
//
//   max_k_greedy  O(n)      monotonic stack: pop a trailing digit the current
//                           one beats, while discards remain
//   max_k_window  O(n*k)    repeatedly take the leftmost largest digit of the
//                           window that still leaves t-1 digits behind
//   max_k_dp      O(n*k)    best(i,j) = max(d[i]*10^(j-1)+best(i+1,j-1),
//                           best(i+1,j)), rolled over two rows
//   brute         O(C(n,k)) every k-subset, spelled out
//
// The four take (d, off, n, k): the bank's digits live at d[off .. off+n) of
// one flat array, so no bank is ever copied to be solved.
//
// build: ../../../refs/ycc.ref day03.y -o day03
// run:   ./day03            (input.txt -> both answers)
//        ./day03 --check    (property battery, no reference file)
//        ./day03 --help
import fs;

const CH_0 = 48;                // '0'
const CH_9 = 57;                // '9'

const K1 = 2;                  // batteries per bank, part 1 (statement)
const K2 = 12;                 // batteries per bank, part 2 (write-up)

// The longest bank the fixed buffers will take.  The real input's banks are
// 100 digits; a longer one is REFUSED with a message rather than trapped on.
const CAP = 1024;

// A parsed input: `d` holds every digit of every bank end to end, `at[i]` is
// where bank i starts, `n[i]` how many digits it has.
type Banks = { d: [long], at: [long], n: [long] };

// Facts about the vendored input.txt, counted from OUTSIDE this program with
// `wc -l input.txt` and `awk '{print length}' input.txt | sort -u`.  --check
// asserts them, so a parser that silently drops or truncates a bank cannot
// pass by agreeing with itself.
const EXPECT_BANKS = 200;
const EXPECT_LEN = 100;

// ── fixed working buffers ────────────────────────────────────────────────────
// Hoisted out of every loop on purpose: the heap is an arena, so a literal
// array inside a loop would allocate per iteration and never be reclaimed.
// The four that get PASSED to a function are plain `[long]` rather than
// `[long; N]`: a fixed-length array is its own type and will not unify with
// `[long]`, so `[0; N]` there is a compile error, not a silent copy.
let STACK: [long; 1024] = [0; 1024];   // the greedy's stack
let ROW_A: [long; 24] = [0; 24];       // the DP's row for best(i+1, j)
let ROW_B: [long; 24] = [0; 24];       // ... and for best(i, j)
let OUTBUF: [long; 24] = [0; 24];      // a value's digits, most significant
let SMALL: [long] = [0; 8];            // the bank being exhaustively checked
let WIN: [long] = [0; 1024];           // a bank plus one appended battery
let VALS: [long] = [0; 1024];          // per-bank joltage, to be ranked
let WHO: [long] = [0; 1024];           // bank numbers, ranked alongside VALS
let HIST_A: [long; 32] = [0; 32];      // value histograms, for the sort check
let HIST_B: [long; 32] = [0; 32];

const POW10: [long; 24] = [1, 10, 100, 1000, 10000, 100000, 1000000,
    10000000, 100000000, 1000000000, 10000000000, 100000000000,
    1000000000000, 10000000000000, 100000000000000, 1000000000000000,
    10000000000000000, 100000000000000000, 1000000000000000000,
    10000000000000000000, 100000000000000000000,
    1000000000000000000000, 10000000000000000000000,
    100000000000000000000000];

// ── --check bookkeeping (globals, not captures) ─────────────────────────────
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";
let ex_cases = 0;               // (bank, k) pairs in the exhaustive sweep
let ex_hits = 0;                // engine-vs-brute agreements (3 per pair)
let ex_bad = 0;                 // disagreements
let ex_sum = 0;                 // sum of every brute value (non-zero guard)
let ex_max = -1;
let ex_min = -1;
let ex_mono = 0;                // strictly-increasing-in-k confirmations
let ex_sub = 0;                 // answers that really are subsequences
let ex_whole = 0;               // V(n) == the whole bank
let ex_strings = 0;             // distinct banks enumerated

// The exhaustive sweep's space: every string over ALPHA of length 1..EX_LEN.
// Both constants are quoted in README.md, and the number of (bank, k) pairs
// they generate (30948) is asserted, so an accidentally truncated sweep is a
// failure rather than a quiet pass.
const ALPHA: [long; 4] = [1, 2, 5, 9];
const EX_LEN = 6;

// ── helpers ──────────────────────────────────────────────────────────────────

def value_digits(value: long, k: long) -> bool {
    // Fills OUTBUF[0..k) with `value`'s k digits, most significant first.
    // False when `value` does not fit in exactly k digits -- which is how an
    // answer with the wrong number of digits gets caught.
    let v = value;
    let j = k - 1;
    while (j >= 0) {
        OUTBUF[j] = v % 10;
        v = v / 10;
        j = j - 1;
    };
    v == 0
}

def spell_all(d: [long], off: long, n: long) -> long {
    let acc = 0;
    let i = 0;
    while (i < n) {
        acc = acc * 10 + d[off + i];
        i = i + 1;
    };
    acc
}

// Is `value` spellable from d[off .. off+n) as an in-order subsequence?  This
// is the statement's "you cannot rearrange batteries" rule, checked on the
// OUTPUT rather than on the code path that produced it.
def is_subsequence(d: [long], off: long, n: long, k: long, value: long) -> bool {
    if (!value_digits(value, k)) { return false };
    let i = 0;
    let j = 0;
    while (j < k && i < n) {
        if (d[off + i] == OUTBUF[j]) {
            i = i + 1;
            j = j + 1;
        } else {
            i = i + 1;
        };
    };
    j == k
}

// "" when bank `s` is usable with k batteries, otherwise why it is not.  The
// statement guarantees ratings 1..9 and enough batteries; both are checked so
// that a wrong file is reported rather than indexed past the end of a buffer.
def bank_fault(s: str, k: long) -> str {
    let why = "";
    if (k < 1) {
        why = "need at least one battery per bank";
    } else if (s.length == 0) {
        why = "empty bank";
    } else if (s.length > CAP) {
        why = "bank has " + tostring(s.length) + " digits, past the " +
            tostring(CAP) + " this build buffers for";
    } else {
        // The characters first: "not a digit at column 3" says more about a
        // short bank than "fewer than the 12 this part needs" does.
        let j = 0;
        while (j < s.length && why == "") {
            let c = s[j];
            if (c < CH_0 || c > CH_9) {
                why = "not a digit at column " + tostring(j + 1);
            } else if (c - CH_0 < 1) {
                why = "joltage rating " + tostring(c - CH_0) + " at column " +
                    tostring(j + 1) + " is below 1";
            };
            j = j + 1;
        };
        if (why == "" && s.length < k) {
            why = "bank has " + tostring(s.length) + " batteries, fewer than the " +
                tostring(k) + " this part needs";
        };
    };
    why
}

def parse_banks(lines: [str]) -> Banks {
    let d: [long] = [];
    let at: [long] = [];
    let n: [long] = [];
    foreach (line in lines) {
        at += len(d);
        n += line.length;
        let j = 0;
        while (j < line.length) {
            d += line[j] - CH_0;
            j = j + 1;
        };
    };
    { d: d, at: at, n: n }
}

// ── engine 1: greedy, O(n) ──────────────────────────────────────────────────

// The largest number spellable from exactly k of d[off .. off+n), in order.
// Keep a stack of the digits chosen so far and, while discards remain, drop a
// trailing digit that the current one beats.  What is left is
// non-increasing, so the leftover discards go off the tail.
// Call only when n >= k >= 1.  Every caller here has already refused a short
// bank through bank_fault, but the guards below return an unmistakable
// sentinel rather than reading past the stack: without them a k > n call is
// SILENT garbage, because `drop` goes negative and `keep` runs off the top.
def max_k_greedy(d: [long], off: long, n: long, k: long) -> long {
    if (k > n) { return -1 };
    let top = 0;
    let drop = n - k;
    let i = 0;
    while (i < n) {
        let v = d[off + i];
        while (top > 0 && drop > 0 && STACK[top - 1] < v) {
            top = top - 1;
            drop = drop - 1;
        };
        STACK[top] = v;
        top = top + 1;
        i = i + 1;
    };
    let keep = top - drop;
    let acc = 0;
    let j = 0;
    while (j < keep) {
        acc = acc * 10 + STACK[j];
        j = j + 1;
    };
    acc
}

// ── engine 2: window scan, O(n*k) ───────────────────────────────────────────

// Fill the joltage from the most significant digit down.  For each position
// take the largest digit available in d[off+pos .. off+n-t] -- the window
// ends at n-t so that t-1 batteries still follow -- preferring the leftmost,
// which leaves the most room.  This is the algorithm the write-ups use.
def max_k_window(d: [long], off: long, n: long, k: long) -> long {
    if (k > n) { return -1 };
    let pos = 0;
    let acc = 0;
    let t = k;
    while (t >= 1) {
        let hi = n - t;
        let best = -1;
        let at = pos;
        let i = pos;
        while (i <= hi) {
            if (d[off + i] > best) {
                best = d[off + i];
                at = i;
            };
            i = i + 1;
        };
        acc = acc * 10 + best;
        pos = at + 1;
        t = t - 1;
    };
    acc
}

// ── engine 3: dynamic program, O(n*k) ───────────────────────────────────────

// best(i, j) = the largest j-digit number spellable from d[off+i .. off+n).
//   best(i, 0) = 0                   the empty number
//   best(n, j) = IMPOSSIBLE          for j >= 1: no digits left to take
//   best(i, j) = max(d[i]*10^(j-1) + best(i+1, j-1),   take d[i] as the head
//                    best(i+1, j))                      or start later
// Two rolling rows of k+1 entries.  No cleverness at all, which is the point:
// a completely independent derivation of the same number.
//
// IMPOSSIBLE, not 0, for "no such choice": with 0 there, a shorter result
// poses as a k-digit one -- on "811111111111119" with k=2 the lone 9 in the
// tens place scored 90 and beat the true 89.  --check caught that.
const IMPOSSIBLE = -1000000000000000;    // far below any 12-digit joltage

def max_k_dp(d: [long], off: long, n: long, k: long) -> long {
    if (k > n) { return IMPOSSIBLE };
    ROW_A[0] = 0;               // best(i, 0): the empty number, always 0
    let j = 1;                  // j starts at 1: best(i, 0) is NOT impossible
    while (j <= k) {
        ROW_A[j] = IMPOSSIBLE;
        j = j + 1;
    };
    let i = n - 1;
    while (i >= 0) {
        let t = 1;
        while (t <= k) {
            let head = d[off + i] * POW10[t - 1] + ROW_A[t - 1];
            let skip = ROW_A[t];
            ROW_B[t] = head;
            if (skip > head) { ROW_B[t] = skip };
            t = t + 1;
        };
        t = 1;
        while (t <= k) {
            ROW_A[t] = ROW_B[t];
            t = t + 1;
        };
        i = i - 1;
    };
    ROW_A[k]
}

// ── engine 4: brute force, O(C(n,k) * k) ────────────────────────────────────

// Walks every choice of the remaining k-depth digits from d[off+start..off+n),
// spelling each one out and keeping the largest.
def brute_from(d: [long], off: long, n: long, k: long, start: long, depth: long,
    acc: long, best: long) -> long {
    let b = best;
    if (depth == k) {
        if (acc > b) { return acc };
        return b;
    };
    let last = n - (k - depth);
    let i = start;
    while (i <= last) {
        b = self(d, off, n, k, i + 1, depth + 1, acc * 10 + d[off + i], b);
        i = i + 1;
    };
    b
}

// The largest k-digit joltage, or -1 when k > n (no such choice exists).
// `brute_from` is named rather than reached through `self`: inside `brute`,
// `self` is `brute`.
def brute(d: [long], off: long, n: long, k: long) -> long {
    if (k > n) { -1 } else { brute_from(d, off, n, k, 0, 0, 0, -1) }
}

// ── Y has no sort, so this one is mine ──────────────────────────────────────

// Insertion sort of v[0..n) into descending order, carrying idx[] along, and
// returns how many shifts it made.  Stable -- equal values keep bank order --
// so the printed ranking is deterministic.  It permutes in place: no
// allocation, which matters because the heap is an arena.
def sort_desc(v: [long], idx: [long], n: long) -> long {
    let shifts = 0;
    let i = 1;
    while (i < n) {
        let key = v[i];
        let kid = idx[i];
        let j = i - 1;
        while (j >= 0 && v[j] < key) {
            v[j + 1] = v[j];
            idx[j + 1] = idx[j];
            j = j - 1;
            shifts = shifts + 1;
        };
        v[j + 1] = key;
        idx[j + 1] = kid;
        i = i + 1;
    };
    shifts
}

// ── --check plumbing ─────────────────────────────────────────────────────────

// ── the hand-written sort ────────────────────────────────────────────────────

// Y has no sort, so sort_desc is mine and it gets its own assertions: a
// descending, stable, in-place permutation.  Fixture A is worked out by hand in
// README.md (exact output, exact shift count); fixture B is a deterministic
// 200-value sequence checked for order and for its histogram being preserved.
def check_sort() -> long {
    print("[5] the hand-written insertion sort (Y has no sort)");
    let a: [long] = [5, 5, 3, 9, 1, 9, 0, 7, 5, 2];
    let aw: [long] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    let shifts = sort_desc(a, aw, 10);
    // Descending, and ties in bank order: 9,9,7,5,5,5,3,2,1,0
    let want_a: [long] = [9, 9, 7, 5, 5, 5, 3, 2, 1, 0];
    // ... carried to 3,5,7,0,1,8,2,9,4,6
    let want_w: [long] = [3, 5, 7, 0, 1, 8, 2, 9, 4, 6];
    let i = 0;
    let wrong = 0;
    while (i < 10) {
        if (a[i] != want_a[i] || aw[i] != want_w[i]) { wrong = wrong + 1 };
        i = i + 1;
    };
    assert_true("fixture A sorts to the hand-worked order", wrong == 0,
        "got " + tostring(a[0]) + tostring(a[1]) + tostring(a[2]) + "/" +
        tostring(a[9]) + ", bank " + tostring(aw[0]) + " first");
    // Insertion sort shifts an element once for every smaller element ahead of
    // it, so the shift count is that pair count: for fixture A, 3+3+4+0+4+0+3
    // = 17 (README.md lists the pairs).
    assert_is("fixture A shift count (smaller-element pair count)", shifts, 17);

    // Fixture B: 200 values, deterministic, checked as a permutation.
    let b: [long] = [];
    let bw: [long] = [];
    i = 0;
    while (i < 200) {
        b += (i * 37) % 23;
        bw += i;
        i = i + 1;
    };
    let sum_before = 0;
    i = 0;
    while (i < 32) {
        HIST_A[i] = 0;
        HIST_B[i] = 0;
        i = i + 1;
    };
    i = 0;
    while (i < 200) {
        sum_before = sum_before + b[i];
        HIST_A[b[i]] = HIST_A[b[i]] + 1;
        i = i + 1;
    };
    sort_desc(b, bw, 200);
    let sum_after = 0;
    let not_desc = 0;
    let bad_bank = 0;
    i = 0;
    while (i < 200) {
        sum_after = sum_after + b[i];
        HIST_B[b[i]] = HIST_B[b[i]] + 1;
        if (i > 0 && b[i - 1] < b[i]) { not_desc = not_desc + 1 };
        if (i > 0 && b[i - 1] == b[i] && bw[i - 1] > bw[i]) { bad_bank = bad_bank + 1 };
        i = i + 1;
    };
    assert_is("fixture B: total preserved", sum_after, sum_before);
    assert_true("fixture B: non-increasing", not_desc == 0,
        "out-of-order steps: " + tostring(not_desc));
    assert_true("fixture B: stable (ties keep bank order)", bad_bank == 0,
        "out-of-order ties: " + tostring(bad_bank));
    let hist_bad = 0;
    i = 0;
    while (i < 32) {
        if (HIST_A[i] != HIST_B[i]) { hist_bad = hist_bad + 1 };
        i = i + 1;
    };
    assert_true("fixture B: every value kept its multiplicity", hist_bad == 0,
        "values whose count changed: " + tostring(hist_bad));
    0
}
// A named numeric assertion: prints ok/FAIL with both sides, so a FAIL says
// which one moved.
def assert_is(label: str, got: long, want_v: long) -> long {
    checks_run = checks_run + 1;
    let detail = label + ": got " + tostring(got) + ", want " + tostring(want_v);
    if (got == want_v) {
        print("  ok   " + detail);
        0
    } else {
        checks_failed = checks_failed + 1;
        if (first_failure == "") { first_failure = detail };
        print("  FAIL " + detail);
        1
    }
}

def assert_true(label: str, cond: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    let text = label + ": " + detail;
    if (cond) {
        print("  ok   " + text);
        0
    } else {
        checks_failed = checks_failed + 1;
        if (first_failure == "") { first_failure = text };
        print("  FAIL " + text);
        1
    }
}

// Tally a failure found in a bulk loop (no per-item printing: there can be
// tens of thousands of items).
def note_fail(detail: str) -> long {
    checks_failed = checks_failed + 1;
    if (first_failure == "") { first_failure = detail };
    0
}

def tally(label: str, bad: long, items: long) -> long {
    checks_run = checks_run + 1;
    if (bad == 0) {
        print(f"  ok   {label}: all {items} clean");
        0
    } else {
        print(f"  FAIL {label}: {bad} bad of {items}");
        note_fail(label + ": " + tostring(bad) + " bad of " + tostring(items));
        1
    }
}

// ── the anchors: the statement's example, and the write-up's ────────────────

// The four banks the statement prints.  Per-line arithmetic for both k values
// is written out in README.md.
const EX1: [str; 4] = ["987654321111111", "811111111111119",
    "234234234234278", "818181911112111"];

// The joltage of a bank given as a string literal, through the greedy.
// A bank shorter than k has no k-digit joltage; -1 says so rather than
// letting the engine answer with whatever the buffer held.
def ex_bank(bank: str, k: long) -> long {
    if (bank.length < k) { return -1 };
    let d: [long] = [];
    let j = 0;
    while (j < bank.length) {
        d += bank[j] - CH_0;
        j = j + 1;
    };
    max_k_greedy(d, 0, len(d), k)
}

def check_anchors() -> long {
    print("[1] the anchors: the statement's example, and the write-up's");
    // Part 1, straight out of the statement: 98 + 89 + 78 + 92 = 357.
    assert_is("example bank 1, k=2 (statement: 98)", ex_bank(EX1[0], K1), 98);
    assert_is("example bank 2, k=2 (statement: 89)", ex_bank(EX1[1], K1), 89);
    assert_is("example bank 3, k=2 (statement: 78)", ex_bank(EX1[2], K1), 78);
    assert_is("example bank 4, k=2 (statement: 92)", ex_bank(EX1[3], K1), 92);
    assert_is("example total, k=2 (statement: 357)",
        ex_bank(EX1[0], K1) + ex_bank(EX1[1], K1) + ex_bank(EX1[2], K1) +
        ex_bank(EX1[3], K1), 357);

    // Part 2, k=12: the write-up's example total, 3121910778619.
    assert_is("example bank 1, k=12", ex_bank(EX1[0], K2), 987654321111);
    assert_is("example bank 2, k=12", ex_bank(EX1[1], K2), 811111111119);
    assert_is("example bank 3, k=12", ex_bank(EX1[2], K2), 434234234278);
    assert_is("example bank 4, k=12", ex_bank(EX1[3], K2), 888911112111);
    assert_is("example total, k=12 (write-up: 3121910778619)",
        ex_bank(EX1[0], K2) + ex_bank(EX1[1], K2) + ex_bank(EX1[2], K2) +
        ex_bank(EX1[3], K2), 3121910778619);

    // All four engines, on the anchors, for every k from 1 to 12.
    let i = 0;
    while (i < 4) {
        let d: [long] = [];
        let j = 0;
        while (j < EX1[i].length) {
            d += EX1[i][j] - CH_0;
            j = j + 1;
        };
        let kk = 1;
        while (kk <= K2) {
            let g = max_k_greedy(d, 0, len(d), kk);
            let w = max_k_window(d, 0, len(d), kk);
            let p = max_k_dp(d, 0, len(d), kk);
            let b = brute(d, 0, len(d), kk);
            assert_true(f"anchor bank {i + 1}, k={kk}: four engines agree",
                g == w && w == p && p == b,
                f"greedy={g} window={w} dp={p} brute={b}");
            kk = kk + 1;
        };
        i = i + 1;
    };
    0
}

// ── micro-cases, worked out by hand in README.md ────────────────────────────

def check_micro() -> long {
    print("[2] hand-computed micro-cases (README.md shows the arithmetic)");
    // "You cannot rearrange batteries": the 9 comes first, so 19, not 91.
    assert_is("\"19\", k=2 -- order is not rearranged", ex_bank("19", K1), 19);
    assert_is("\"91\", k=2 -- the mirror image does give 91", ex_bank("91", K1), 91);
    assert_is("\"123456789\", k=2 -- the two biggest, in order",
        ex_bank("123456789", K1), 89);
    assert_is("\"987654321\", k=2 -- the two biggest, in order",
        ex_bank("987654321", K1), 98);
    assert_is("\"12345\", k=2 -- 4 then 5; only the last 4 can be tens",
        ex_bank("12345", K1), 45);
    assert_is("\"55555\", k=2 -- every choice gives 55", ex_bank("55555", K1), 55);
    assert_is("\"1\", k=1 -- the smallest bank", ex_bank("1", 1), 1);
    assert_is("\"9\", k=1 -- the only battery", ex_bank("9", 1), 9);
    assert_is("\"123456789\", k=1 -- the largest battery",
        ex_bank("123456789", 1), 9);
    assert_is("\"987654321\", k=9 -- k == n, take the whole bank",
        ex_bank("987654321", K2 - 3), 987654321);
    assert_is("\"111111111111111\", k=12 -- fifteen ones, drop three",
        ex_bank("111111111111111", K2), 111111111111);
    assert_is("\"999999999999999\", k=12 -- fifteen nines, drop three",
        ex_bank("999999999999999", K2), 999999999999);
    assert_is("\"999999999999\", k=12 -- k == n, take the whole bank",
        ex_bank("999999999999", K2), 999999999999);
    // The window's right edge bites: the leading 8 is the largest digit, but
    // taking it would leave 14 batteries and only 11 are needed, so a
    // correct solver reaches past it for the 9 at column 3.
    assert_is("\"819191911111111\", k=12 -- the window's right edge bites",
        ex_bank("819191911111111", K2), 991911111111);
    // A bank one battery short of k: refused, not answered.
    assert_is("\"11111111111\", k=12 -- eleven batteries is refused",
        ex_bank("11111111111", K2), -1);
    0
}

// The edge cases the statement calls out are refusals, not answers: a bank
// with fewer than k batteries has no k-digit joltage at all.  Each must be
// reported with a message and a non-zero exit, never a trap.
def check_validator() -> long {
    print("[3] the statement's edge cases are refused, not trapped");
    assert_true("bank \"12\" with k=12 is refused",
        bank_fault("12", K2) != "", bank_fault("12", K2));
    assert_true("bank \"987654321\" with k=12 is refused",
        bank_fault("987654321", K2) != "", bank_fault("987654321", K2));
    assert_true("exactly k batteries is accepted",
        bank_fault("987654321", K2 - 3) == "", bank_fault("987654321", K2 - 3));
    assert_true("an empty bank is refused",
        bank_fault("", K1) != "", bank_fault("", K1));
    assert_true("a non-digit is refused",
        bank_fault("12a45", K1) != "", bank_fault("12a45", K1));
    assert_true("a rating below 1 is refused",
        bank_fault("102345", K1) != "", bank_fault("102345", K1));
    assert_true("k=0 is refused",
        bank_fault("12345", 0) != "", bank_fault("12345", 0));
    assert_true("a 20-digit bank is accepted",
        bank_fault("11111111111111111111", K1) == "",
        bank_fault("11111111111111111111", K1));
    // One past the buffer cap must be refused by name, not overrun.
    let big = "";
    let j = 0;
    while (j <= CAP) { big += "1"; j = j + 1 };
    assert_true("a bank one digit past the cap is refused",
        bank_fault(big, K1) != "", bank_fault(big, K1));
    assert_true("a bank exactly at the cap is accepted",
        bank_fault(big[0:big.length - 1], K1) == "", tostring(CAP) + " digits");
    0
}

// ── the proof: greedy == window == dp == brute, exhaustively ────────────────

// Every string over ALPHA of length 1..EX_LEN, prefix by prefix, and for
// every k in 1..n all four engines.  Nothing here is sampled: the space is
// enumerated.  At each node it also checks that the answer really is a
// subsequence of the bank, that V(k) rises strictly with k, and that V(n) is
// the whole bank.  Returns the number of banks enumerated.
def exhaustive(depth: long, n: long) -> long {
    let banks = 0;
    if (n >= 1) {
        banks = 1;
        let prev = 0;
        let kk = 1;
        while (kk <= n) {
            let g = max_k_greedy(SMALL, 0, n, kk);
            let w = max_k_window(SMALL, 0, n, kk);
            let p = max_k_dp(SMALL, 0, n, kk);
            let b = brute(SMALL, 0, n, kk);
            ex_cases = ex_cases + 1;
            ex_sum = ex_sum + b;
            if (b > ex_max) { ex_max = b };
            if (ex_min < 0 || b < ex_min) { ex_min = b };
            if (g == b) { ex_hits = ex_hits + 1 };
            if (w == b) { ex_hits = ex_hits + 1 };
            if (p == b) { ex_hits = ex_hits + 1 };
            if (g != b || w != b || p != b) {
                ex_bad = ex_bad + 1;
                if (first_failure == "") {
                    first_failure = "exhaustive: bank of length " + tostring(n) +
                        ", k=" + tostring(kk) + ": greedy=" + tostring(g) +
                        " window=" + tostring(w) + " dp=" + tostring(p) +
                        " brute=" + tostring(b);
                };
            };
            // The answer must be spellable from the bank, in order.
            if (is_subsequence(SMALL, 0, n, kk, g)) { ex_sub = ex_sub + 1 };
            // V(k) rises strictly with k: V(k) <= 10^k - 1 < 10^k <= V(k+1).
            if (g > prev) { ex_mono = ex_mono + 1 } else { ex_bad = ex_bad + 1 };
            prev = g;
            kk = kk + 1;
        };
        // k == n takes the whole bank.
        if (max_k_greedy(SMALL, 0, n, n) == spell_all(SMALL, 0, n)) {
            ex_whole = ex_whole + 1;
        };
    };
    if (depth < EX_LEN) {
        let a = 0;
        while (a < 4) {
            SMALL[n] = ALPHA[a];
            banks = banks + self(depth + 1, n + 1);
            a = a + 1;
        };
    };
    banks
}

def check_exhaustive() -> long {
    print("[4] exhaustive: every bank over {1,2,5,9} of length 1..6, every k");
    ex_strings = exhaustive(0, 0);
    // The space's size, derived on paper: sum over L of L * 4^L = 30948.
    assert_is("(bank, k) pairs enumerated", ex_cases, 30948);
    assert_is("distinct banks enumerated", ex_strings, 5460);
    assert_is("engine-vs-brute agreements (3 per pair)", ex_hits, 3 * 30948);
    assert_is("disagreements", ex_bad, 0);
    assert_is("answers that are in-order subsequences", ex_sub, 30948);
    assert_is("strictly-increasing-in-k confirmations", ex_mono, 30948);
    assert_is("k == n takes the whole bank", ex_whole, 5460);
    // Non-vacuity: the sweep really produced numbers, spread over a wide
    // range, and the extremes are the ones a hand calculation gives.
    assert_true("every brute value was present and positive", ex_sum > 0,
        "sum of all brute values = " + tostring(ex_sum));
    assert_is("largest value in the space", ex_max, 999999);
    assert_is("smallest value in the space", ex_min, 1);
    print("  note: sweep total " + tostring(ex_sum) + " over " +
        tostring(ex_cases) + " pairs; no reference file is involved");
    0
}

// ── the real input, cross-checked three ways ────────────────────────────────

// An independent re-read of the file as raw bytes: count the digit runs
// without going through fs.read_lines.  If the line parser and this disagree,
// one of them is wrong -- and neither can pass by being empty, because the
// expected count comes from the shell (wc -l), not from this program.
def rescan(path: str) -> long {
    let bytes: [byte]? = fs.read_bytes(path);
    if (bytes == none) { return -1 };
    let banks = 0;
    let in_bank = false;
    let i = 0;
    while (i < len(bytes!)) {
        let c = bytes![i];
        if (c >= CH_0 && c <= CH_9) {
            if (!in_bank) {
                banks = banks + 1;
                in_bank = true;
            };
        } else {
            in_bank = false;
        };
        i = i + 1;
    };
    banks
}

def check_real(path: str) -> long {
    print("[6] the real input: three engines, and invariants on the answers");
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        assert_true("input.txt is readable", false, "cannot read " + path);
        return 1;
    };
    assert_true("input.txt is readable", true, path + " opened");
    let lines_rescan = rescan(path);
    // --check must not be able to pass on an absent or empty input.
    assert_is("banks in input.txt (wc -l, from the shell)", len(lines!), EXPECT_BANKS);
    assert_is("banks seen by the independent byte rescan", lines_rescan, EXPECT_BANKS);
    assert_true("both bank counts are non-zero",
        len(lines!) > 0 && lines_rescan > 0,
        "line parse " + tostring(len(lines!)) + ", byte rescan " +
        tostring(lines_rescan));

    let b = parse_banks(lines!);
    let nb = len(b.n);
    assert_is("parsed banks", nb, EXPECT_BANKS);

    let bad_i = 0;
    let i = 0;
    while (i < nb) {
        let why = bank_fault(lines![i], K1);
        if (why != "" && bad_i == 0) {
            bad_i = i + 1;
            print("  FAIL bank " + tostring(i + 1) + ": " + why);
            note_fail("real input bank " + tostring(i + 1) + ": " + why);
        };
        i = i + 1;
    };
    assert_true("every bank is a run of ratings 1..9", bad_i == 0,
        "checked " + tostring(nb) + " banks");

    let shortest = 99999;
    let longest = 0;
    let total_digits = 0;
    i = 0;
    while (i < nb) {
        if (b.n[i] < shortest) { shortest = b.n[i] };
        if (b.n[i] > longest) { longest = b.n[i] };
        total_digits = total_digits + b.n[i];
        i = i + 1;
    };
    assert_is("shortest bank (awk '{print length}' | sort -u)", shortest, EXPECT_LEN);
    assert_is("longest bank", longest, EXPECT_LEN);
    assert_is("batteries in total", total_digits, EXPECT_BANKS * EXPECT_LEN);

    // Per bank, per k: the three efficient engines must agree, the answer must
    // be a real in-order subsequence, V(k) must rise strictly with k, and
    // appending a battery must never lower it.
    let mismatches = 0;
    let subs = 0;
    let nonmono = 0;
    let nonmono_app = 0;
    let app_tested = 0;
    let pairs = 0;
    i = 0;
    while (i < nb) {
        let s = b.at[i];
        let n = b.n[i];
        let prev = 0;
        let kk = 1;
        while (kk <= K2) {
            let g = max_k_greedy(b.d, s, n, kk);
            let w = max_k_window(b.d, s, n, kk);
            let p = max_k_dp(b.d, s, n, kk);
            pairs = pairs + 1;
            if (g != w || w != p) { mismatches = mismatches + 1 };
            if (is_subsequence(b.d, s, n, kk, g)) { subs = subs + 1 };
            if (g <= prev) { nonmono = nonmono + 1 };
            if (n + 1 <= CAP) {
                let j = 0;
                while (j < n) { WIN[j] = b.d[s + j]; j = j + 1 };
                WIN[n] = 1;                 // one extra battery, rating 1
                if (max_k_greedy(WIN, 0, n + 1, kk) < g) { nonmono_app = nonmono_app + 1 };
                app_tested = app_tested + 1;
            };
            prev = g;
            kk = kk + 1;
        };
        i = i + 1;
    };
    tally("greedy, window scan and DP agree on the real input", mismatches, pairs);
    tally("real-input answers are in-order subsequences of their bank",
        pairs - subs, pairs);
    tally("V(k) rises strictly with k on every real bank", nonmono, pairs);
    tally("appending a battery never lowers V(k)", nonmono_app, app_tested);
    assert_is("append-monotonicity ran on every pair (never skipped)",
        app_tested, pairs);

    // The two totals, computed three independent ways, with the invariants
    // that bound them.  Every observed value is demanded non-zero BEFORE it is
    // compared with anything.
    let sum1 = 0;
    let sum2 = 0;
    let sum1_w = 0;
    let sum2_w = 0;
    let sum1_p = 0;
    let sum2_p = 0;
    let min1 = 99999;
    let max1 = 0;
    i = 0;
    while (i < nb) {
        let v1 = max_k_greedy(b.d, b.at[i], b.n[i], K1);
        let v2 = max_k_greedy(b.d, b.at[i], b.n[i], K2);
        sum1 = sum1 + v1;
        sum2 = sum2 + v2;
        sum1_w = sum1_w + max_k_window(b.d, b.at[i], b.n[i], K1);
        sum2_w = sum2_w + max_k_window(b.d, b.at[i], b.n[i], K2);
        sum1_p = sum1_p + max_k_dp(b.d, b.at[i], b.n[i], K1);
        sum2_p = sum2_p + max_k_dp(b.d, b.at[i], b.n[i], K2);
        if (v1 < min1) { min1 = v1 };
        if (v1 > max1) { max1 = v1 };
        i = i + 1;
    };
    assert_true("part 1 total is present and non-zero", sum1 > 0,
        "part 1 total = " + tostring(sum1));
    assert_true("part 2 total is present and non-zero", sum2 > 0,
        "part 2 total = " + tostring(sum2));
    assert_is("part 1 total: greedy == window scan", sum1_w, sum1);
    assert_is("part 1 total: greedy == DP", sum1_p, sum1);
    assert_is("part 2 total: greedy == window scan", sum2_w, sum2);
    assert_is("part 2 total: greedy == DP", sum2_p, sum2);
    // Each bank contributes a k-digit number, so the total is pinned.
    assert_true("part 1 total is at least banks * 10", sum1 >= nb * 10,
        tostring(nb) + " banks, each at least 10");
    assert_true("part 1 total is at most banks * 99", sum1 <= nb * 99,
        tostring(nb) + " banks, each at most 99");
    assert_true("part 2 total is at least banks * 10^11", sum2 >= nb * POW10[K2 - 1],
        tostring(nb) + " banks, each at least " + tostring(POW10[K2 - 1]));
    assert_true("part 2 total is at most banks * (10^12 - 1)",
        sum2 <= nb * (POW10[K2] - 1),
        tostring(nb) + " banks, each at most " + tostring(POW10[K2] - 1));
    // More batteries per bank means a strictly larger number per bank.
    assert_true("part 2 total exceeds part 1 total", sum2 > sum1,
        tostring(sum2) + " > " + tostring(sum1));
    print("  note: real-input totals part 1 = " + tostring(sum1) +
        ", part 2 = " + tostring(sum2) + "; per-bank part 1 joltage " +
        tostring(min1) + ".." + tostring(max1));

    // The ranking the default run prints: sort the real part-2 values and
    // check the winner against a plain linear-scan maximum.
    let top = -1;
    let j = 0;
    while (j < 32) { HIST_A[j] = 0; j = j + 1 };
    i = 0;
    while (i < nb) {
        let v2 = max_k_greedy(b.d, b.at[i], b.n[i], K2);
        VALS[i] = v2;
        WHO[i] = i + 1;
        if (v2 > top) { top = v2 };
        // per-bank part-2 joltage is 12 digits: bucket the leading digits
        let lead = (v2 / POW10[K2 - 1]) % 10;
        if (lead >= 0 && lead < 32) { HIST_A[lead] = HIST_A[lead] + 1 };
        i = i + 1;
    };
    sort_desc(VALS, WHO, nb);
    assert_is("ranked top bank equals the linear-scan maximum", VALS[0], top);
    let unordered = 0;
    let untied = 0;
    i = 1;
    while (i < nb) {
        if (VALS[i - 1] < VALS[i]) { unordered = unordered + 1 };
        if (VALS[i - 1] == VALS[i] && WHO[i - 1] > WHO[i]) { untied = untied + 1 };
        i = i + 1;
    };
    assert_true("the real-input ranking is non-increasing", unordered == 0,
        "out-of-order steps: " + tostring(unordered) + " over " + tostring(nb) +
        " ranked values; winner " + tostring(VALS[0]) + " from bank #" +
        tostring(WHO[0]));
    assert_true("the real-input ranking is stable", untied == 0,
        "out-of-order ties: " + tostring(untied));
    let buckets = 0;
    j = 0;
    while (j < 10) { buckets = buckets + HIST_A[j]; j = j + 1 };
    assert_true("every bank has a 12-digit joltage (bucketed by leading digit)",
        buckets == nb, "bucketed " + tostring(buckets) + " of " + tostring(nb) +
        " banks");
    0
}

// ── --bench: time the hot loop and show that it allocates nothing ───────────
// Behind a flag because it reads the clock.  The heap is an arena, so a
// ten-times-repeated pass must not move heap_used() at all: if it does, some
// literal array or string is being built inside the loop.
def bench(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day03: cannot read " + path + "\n");
        return 1;
    };
    let b = parse_banks(lines!);
    let nb = len(b.n);
    let acc = 0;
    let r = 0;
    while (r < 10) {
        let i = 0;
        while (i < nb) {
            acc = acc + max_k_greedy(b.d, b.at[i], b.n[i], K2);
            i = i + 1;
        };
        r = r + 1;
    };
    let t0 = clock_us();
    let h0 = heap_used();
    r = 0;
    while (r < 100) {
        let i = 0;
        while (i < nb) {
            acc = acc + max_k_greedy(b.d, b.at[i], b.n[i], K2);
            i = i + 1;
        };
        r = r + 1;
    };
    let h1 = heap_used();
    let t1 = clock_us();
    print(f"bench: {nb} banks of {b.n[0]} digits, 100 passes of max_k_greedy(k={K2})");
    print(f"bench: {t1 - t0} us total, {(t1 - t0) / 100} us per pass");
    print(f"bench: heap_used {h0} -> {h1} (delta {h1 - h0} bytes over 100 passes)");
    print(f"bench: checksum {acc} (discards the result; keeps the loop honest)");
    0
}

def run_check() -> long {
    print("day03: property check -- no reference file is involved");
    print("");
    check_anchors();
    check_micro();
    check_validator();
    check_exhaustive();
    check_sort();
    check_real("input.txt");
    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED (first: {first_failure})");
    1
}

// ── the answer ───────────────────────────────────────────────────────────────

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day03: cannot read " + path + "\n");
        return 1;
    };
    if (len(lines!) == 0) {
        eputs("day03: " + path + " holds no banks\n");
        return 1;
    };
    // Report the first bank that cannot be used for a given k, rather than
    // indexing past the end of a fixed buffer.  No traps on any path.
    let i = 0;
    while (i < len(lines!)) {
        let why = bank_fault(lines![i], K2);
        if (why != "") {
            eputs("day03: " + path + " bank " + tostring(i + 1) + ": " + why + "\n");
            return 1;
        };
        i = i + 1;
    };

    let b = parse_banks(lines!);
    let nb = len(b.n);
    let sum1 = 0;
    let sum2 = 0;
    let min1 = 99999;
    let max1 = 0;
    let shortest = 99999;
    let longest = 0;
    let total_digits = 0;
    i = 0;
    while (i < nb) {
        let n = b.n[i];
        let s = b.at[i];
        let v1 = max_k_greedy(b.d, s, n, K1);
        let v2 = max_k_greedy(b.d, s, n, K2);
        sum1 = sum1 + v1;
        sum2 = sum2 + v2;
        if (v1 < min1) { min1 = v1 };
        if (v1 > max1) { max1 = v1 };
        if (n < shortest) { shortest = n };
        if (n > longest) { longest = n };
        total_digits = total_digits + n;
        VALS[i] = v2;
        WHO[i] = i + 1;
        i = i + 1;
    };
    let shifts = sort_desc(VALS, WHO, nb);

    print("day03: Advent of Code 2025 day 3 -- Lobby");
    print(f"input: {path}");
    print(f"banks: {nb}");
    print(f"batteries: {total_digits} (per bank {shortest}..{longest})");
    print(f"batteries per bank: part 1 = {K1}, part 2 = {K2}");
    print(f"part 1 (total output joltage, {K1} per bank): {sum1}");
    print(f"part 2 (total output joltage, {K2} per bank): {sum2}");
    print(f"part 1 per-bank joltage: {min1}..{max1}");
    let t = 0;
    while (t < 3 && t < nb) {
        print(f"  best bank #{WHO[t]}: {VALS[t]} ({K2} digits)");
        t = t + 1;
    };
    print(f"ranking of {nb} banks by part 2: {shifts} insertion-sort shifts");
    0
}

const HELP = "day03 -- Advent of Code 2025 day 3 (Lobby), in Y

usage:
  ./day03 [FILE]        solve FILE (default input.txt) and print both answers
  ./day03 --check       run the property battery and print every assertion
  ./day03 --bench       time the hot loop and show heap_used() does not move
  ./day03 --help        this text

Each line of FILE is a bank of batteries rated 1..9.  Turn on exactly k of
them, in their original order, and the bank produces the number those digits
spell; every bank contributes its largest such number, and the answers are
the sums over banks.

  part 1  k = 2     (the puzzle statement)
  part 2  k = 12    (from a public write-up, NOT from AoC: part 2 of every
                    2025 puzzle sits behind a login.  README.md names the
                    source and both example values that anchor it.)

--check runs the statement's and the write-up's example anchors, hand-computed
micro-cases, the statement's refusal cases, an exhaustive proof that four
independent engines agree over every bank of length 1..6 drawn from
{1,2,5,9} (30948 (bank, k) pairs, none sampled), and a three-way
cross-check plus invariants on the real input.
";

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let want_bench = false;
    let have_path = false;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check" || a == "--self-test") {
            want_check = true;
        } else if (a == "--bench") {
            want_bench = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day03: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day03: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day03: more than one input file given (try --help)\n");
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
    if (want_bench) { return bench(path) };
    solve(path)
};
exit(main())
