// day01.y -- Advent of Code 2025, day 1 ("Secret Entrance"), in Y.
//
// A safe dial numbered 0..99 starts at 50 and follows a list of rotations,
// one per line, each an 'L' or 'R' and a distance.  Turning past 99 wraps to
// 0 and turning left past 0 wraps to 99.
//
//   part 1  how many rotations LEAVE the dial pointing at 0
//   part 2  how many individual CLICKS leave it pointing at 0
//
// part 1 is O(n) in the number of rotations; part 2 is computed two ways
// (one click at a time, and in closed form per rotation) and the two are
// asserted to agree.  `--check` runs the property battery; see README.md.
//
// build: ../../../refs/ycc.ref day01.y -o day01
// run:   ./day01            (input.txt -> both answers)
//        ./day01 --check    (property check, no reference file)
//        ./day01 --help
import fs;

const START = 50;                 // the dial starts here (statement)
const MOD = 100;                  // positions 0..99, circular
const CH_L = 76;                  // 'L'
const CH_R = 82;                  // 'R'
const CH_ZERO = 48;               // '0'
const MAX_DIGITS = 18;            // past this a distance could overflow a long

// What a parsed input is: `dirs[i]` is -1 (L) or +1 (R), `dists[i]` the clicks.
type Rots = { dirs: [long], dists: [long] };

// What the independent byte-level rescan of the same file found.
type Scan = { n: long, clicks: long, l: long, r: long };

// --check bookkeeping.  Globals (not captures), so every assert_* can tally.
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

// ── the dial ──────────────────────────────────────────────────────────────────

// p reduced into 0..MOD-1.  Y's `%` truncates towards zero like C, so a
// negative gives a negative; that has to be fixed up by hand or the dial
// walks off into negative positions silently.
def wrap(x: long) -> long {
    let r = x % MOD;
    if (r < 0) { r + MOD } else { r }
}

def is_digit(c: long) -> bool { c >= CH_ZERO && c <= CH_ZERO + 9 }

// The distance of a rotation line, by hand.  Only call this on a line
// `bad_reason` has already accepted: it assumes 'L'/'R' then digits.
def digits_value(line: str) -> long {
    let v = 0;
    let k = 1;
    while (k < line.length) {
        v = v * 10 + (line[k] - CH_ZERO);
        k = k + 1;
    };
    v
}

// "" when `line` is a well-formed rotation, otherwise why it is not.  The
// statement guarantees `[LR][0-9]+`; everything else is a parse failure we
// report rather than guess at (a rotation with a sign, say, or a missing
// distance).
def bad_reason(line: str) -> str {
    let why = "";
    if (line.length == 0) {
        why = "empty line";
    } else if (line[0] != CH_L && line[0] != CH_R) {
        why = "expected a leading 'L' or 'R'";
    } else if (line.length < 2) {
        why = "rotation has no distance";
    } else if (line.length - 1 > MAX_DIGITS) {
        why = "distance has more than " + tostring(MAX_DIGITS) + " digits";
    } else {
        let k = 1;
        let ok = true;
        while (k < line.length && ok) {
            if (is_digit(line[k])) { k = k + 1 } else { ok = false };
        };
        if (!ok) {
            why = "non-digit in the distance at column " + tostring(k + 1);
        };
    };
    why
}

// 1-based line number of the first malformed rotation, or 0 when all are fine.
def first_bad(lines: [str]) -> long {
    let i = 0;
    let bad = 0;
    while (i < len(lines) && bad == 0) {
        if (bad_reason(lines[i]) != "") { bad = i + 1 } else { i = i + 1 };
    };
    bad
}

def parse_lines(lines: [str]) -> Rots {
    let dirs: [long] = [];
    let dists: [long] = [];
    foreach (line in lines) {
        let dir = 1;
        if (line[0] == CH_L) { dir = -1 };
        dirs += dir;
        dists += digits_value(line);
    };
    { dirs: dirs, dists: dists }
}

// ── part 1 ────────────────────────────────────────────────────────────────────

// Method A: follow the dial, wrapping after every rotation.  This is the
// statement's own walk.
def part1_walk(r: Rots) -> long {
    let p = START;
    let hits = 0;
    for i in 0..len(r.dirs) {
        p = wrap(p + r.dirs[i] * r.dists[i]);
        if (p == 0) { hits = hits + 1 };
    };
    hits
}

// Method B: the same count reached from the other end, with NO wrapping
// until the very last step.  `total` is the exact signed sum of every
// rotation, so the position after rotation i is (START + total - the sum
// of the deltas after i) mod 100 -- an independent accumulation order and
// direction, which is what makes it worth comparing against method A.
def part1_reverse(r: Rots) -> long {
    let total = total_delta(r);
    let hits = 0;
    let after = 0;                 // deltas of the rotations after the current one
    let i = len(r.dirs) - 1;
    while (i >= 0) {
        if (wrap(START + total - after) == 0) { hits = hits + 1 };
        after = after + r.dirs[i] * r.dists[i];
        i = i - 1;
    };
    hits
}

// The exact signed sum of every rotation, no modulus anywhere.
def total_delta(r: Rots) -> long {
    let s = 0;
    for i in 0..len(r.dirs) {
        s = s + r.dirs[i] * r.dists[i];
    };
    s
}

def total_clicks(r: Rots) -> long {
    let s = 0;
    for i in 0..len(r.dists) { s = s + r.dists[i] };
    s
}

def final_walk(r: Rots) -> long {
    let p = START;
    for i in 0..len(r.dirs) {
        p = wrap(p + r.dirs[i] * r.dists[i]);
    };
    p
}

// ── part 2 ────────────────────────────────────────────────────────────────────

// Method A: every single click, counted as it happens.  O(total clicks).
def part2_per_click(r: Rots) -> long {
    let p = START;
    let hits = 0;
    for i in 0..len(r.dirs) {
        let dir = r.dirs[i];
        let d = r.dists[i];
        for _k in 1..(d + 1) {
            p = wrap(p + dir);
            if (p == 0) { hits = hits + 1 };
        };
    };
    hits
}

// How many of the first `dist` clicks of a rotation starting at `pos` leave
// the dial at 0.  The click numbers that do are `first`, `first + 100`,
// `first + 200`, ... because the dial is periodic with period 100, so the
// count is exact division.  `first` is the click within 1..100 that lands on
// 0; a position already at 0 is left at k = 0, so its first return is 100.
def hits_in(dist: long, pos: long, dir: long) -> long {
    let k0 = wrap(0 - pos * dir);  // the click in 0..99 that lands on 0
    let first = k0;
    if (k0 == 0) { first = MOD };
    if (dist < first) { 0 } else { (dist - first) / MOD + 1 }
}

// Method B: the closed form, O(1) per rotation.
def part2_closed(r: Rots) -> long {
    let p = START;
    let hits = 0;
    for i in 0..len(r.dirs) {
        hits = hits + hits_in(r.dists[i], p, r.dirs[i]);
        p = wrap(p + r.dirs[i] * r.dists[i]);
    };
    hits
}

// The same, but counting only clicks 1..dist-1 -- the ones strictly inside
// the rotation, i.e. every hit that is not also a rotation's end position.
// part2 must be exactly part1 + this.
def part2_inside(r: Rots) -> long {
    let p = START;
    let hits = 0;
    for i in 0..len(r.dirs) {
        hits = hits + hits_in(r.dists[i] - 1, p, r.dirs[i]);
        p = wrap(p + r.dirs[i] * r.dists[i]);
    };
    hits
}

// ── an independent second read of the file ────────────────────────────────────

// Scan the raw bytes and pull out the digit runs directly: how many
// rotations there are, the sum of their distances, and how many 'L' and 'R'
// bytes there are.  Nothing here goes through read_lines() or the parser, so
// agreeing with `parse_lines` means two unrelated readers saw the same file.
def rescan(b: [byte]) -> Scan {
    let n = 0;
    let clicks = 0;
    let l = 0;
    let r = 0;
    let cur = -1;                  // -1 = between rotations
    let i = 0;
    while (i < len(b)) {
        let c = b[i];
        if (c >= CH_ZERO && c <= CH_ZERO + 9) {
            if (cur < 0) { cur = 0 };
            cur = cur * 10 + (c - CH_ZERO);
        } else {
            if (cur >= 0) { n = n + 1; clicks = clicks + cur; cur = -1 };
            if (c == CH_L) { l = l + 1 } else { if (c == CH_R) { r = r + 1 } };
        };
        i = i + 1;
    };
    if (cur >= 0) { n = n + 1; clicks = clicks + cur };
    { n: n, clicks: clicks, l: l, r: r }
}

// ── the check harness ─────────────────────────────────────────────────────────

def expect(name: str, ok: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    let bad = 0;
    if (ok) {
        print("ok   " + name + "   " + detail + "");
    } else {
        checks_failed = checks_failed + 1;
        bad = 1;
        if (first_failure == "") { first_failure = name };
        print("FAIL " + name + "   " + detail + "");
    };
    bad
}

// ── the property battery ──────────────────────────────────────────────────────

// One hand-worked micro-case, run through the real parser and all four
// counters.  The arithmetic is in README.md so it can be checked by eye.
def micro(label: str, lines: [str], want1: long, want2: long) -> long {
    let r = parse_lines(lines);
    let got1 = part1_walk(r);
    let got2 = part2_per_click(r);
    let got2b = part2_closed(r);
    let got1b = part1_reverse(r);
    let pos = final_walk(r);
    let d = f"part1={got1} part2={got2} closed={got2b} reverse={got1b} final={pos}"
            + f" want {want1}/{want2}";
    let bad = expect("micro " + label, got1 == want1 && got2 == want2, d);
    bad + expect("micro " + label + " methods agree",
                 got1 == got1b && got2 == got2b, d)
}

def check_micro() -> long {
    let f = 0;
    // The statement's own worked example, verbatim: three rotations end on 0
    // (README shows the arithmetic) and six clicks land on 0.
    f = f + micro("statement example",
                  ["L68", "L30", "R48", "L5", "R60", "L55", "L1", "L99", "R14", "L82"],
                  3, 6);
    // The statement's wrap edge case, reached with a legal input: 50 --L45--> 5,
    // 5 --L10--> 95 (passing 0 on the 5th click), 95 --R5--> 0.  part 1 sees
    // only the last, part 2 sees two.
    f = f + micro("statement L10 wrap", ["L45", "L10", "R5"], 1, 2);
    // A whole revolution: passes 0 once on the way and ends where it began,
    // so part 1 is blind to it and part 2 is not.
    f = f + micro("L100 from 50", ["L100"], 0, 1);
    f = f + micro("R100 from 50", ["R100"], 0, 1);
    // Half a revolution: lands on 0, and that click is the last one, so both
    // parts count it.
    f = f + micro("L50 from 50", ["L50"], 1, 1);
    // The real input reaches 999 clicks, i.e. ten whole revolutions: 0 lands
    // at clicks 50, 150, ... 950, and the dial ends at 51.
    f = f + micro("L999 from 50", ["L999"], 0, 10);
    f = f + micro("R999 from 50", ["R999"], 0, 10);
    // A zero-length rotation changes nothing and clicks nothing.  Read
    // strictly ("the dial is LEFT pointing at 0") part 1 counts it; part 2
    // has no click to count.  The real input's smallest distance is 1, so
    // this reading cannot change the answers.
    f = f + micro("L0 while at 0", ["L50", "L0"], 2, 1);
    f
}

// Exhaustive agreement of the two part-2 methods: every position on the
// dial, both directions, every distance through two full revolutions.
def check_hits_exhaustive() -> long {
    let bad = 0;
    for d4 in 0..2 {
        let s = 1 - 2 * d4;         // 0 -> +1 (R), 1 -> -1 (L)
        for pos in 0..100 {
            for d in 0..201 {
                let want = 0;
                let p = pos;
                for k in 1..(d + 1) {
                    p = wrap(p + s);
                    if (p == 0) { want = want + 1 };
                };
                if (hits_in(d, pos, s) != want) { bad = bad + 1 };
            };
        };
    };
    bad
}

// The closed form must gain exactly one hit per added revolution, for every
// state.  Together with the exhaustive table above (which covers 0..200) and
// induction on d that makes it right for every distance, not just the ones
// the real input happens to contain.
def check_periodicity() -> long {
    let bad = 0;
    for d4 in 0..2 {
        let s = 1 - 2 * d4;
        for pos in 0..100 {
            for d in 0..201 {
                if (hits_in(d + MOD, pos, s) != hits_in(d, pos, s) + 1) { bad = bad + 1 };
            };
        };
    };
    bad
}

def check_real(path: str, bytes: [byte]) -> long {
    let f = 0;
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        f = f + expect("input readable", false, "cannot read " + path);
        return f;
    };
    f = f + expect("input readable", true, f"{len(lines!)} lines, {len(bytes)} bytes");

    let bad = first_bad(lines!);
    if (bad != 0) {
        f = f + expect("input well formed", false,
                       "line " + tostring(bad) + ": " + bad_reason(lines![bad - 1]));
        return f;
    };
    f = f + expect("input well formed", true, f"{len(lines!)} rotations, none malformed");

    // An empty file is a wrong file, not an answer of 0.
    if (len(lines!) == 0) {
        f = f + expect("input has rotations", false, path + " holds none");
        return f;
    };
    let r = parse_lines(lines!);
    let n = len(r.dirs);
    let clicks = total_clicks(r);
    let sc = rescan(bytes);

    // Presence guards first: a comparison of two values that are both
    // absent passes trivially, so each observed quantity has to be shown
    // present and non-zero before anything is compared with it.
    f = f + expect("rotations present", n > 0, f"n={n}");
    f = f + expect("clicks present", clicks > 0, f"clicks={clicks}");
    f = f + expect("rescan present", sc.n > 0 && sc.clicks > 0, f"n={sc.n} clicks={sc.clicks}");

    // The parser and the independent byte scan must agree.
    f = f + expect("parse == rescan", sc.n == n && sc.clicks == clicks,
                   f"{sc.n}/{sc.clicks} vs {n}/{clicks}");
    let ls = 0;
    let rs = 0;
    for i in 0..n {
        if (r.dirs[i] < 0) { ls = ls + 1 } else { rs = rs + 1 };
    };
    f = f + expect("directions == rescan", sc.l == ls && sc.r == rs,
                   f"L:{sc.l}/{ls} R:{sc.r}/{rs}");

    // Every distance also has to read the same through the standard
    // builtin as through the hand-rolled digit loop.
    let tolong_bad = 0;
    for i in 0..n {
        if (tolong(lines![i][1:]) != r.dists[i]) { tolong_bad = tolong_bad + 1 };
    };
    f = f + expect("distances == tolong", tolong_bad == 0,
                   f"{tolong_bad} of {n} disagree with tolong()");

    let p1 = part1_walk(r);
    let p1b = part1_reverse(r);
    let p2 = part2_per_click(r);
    let p2b = part2_closed(r);
    let inside = part2_inside(r);
    let pos = final_walk(r);

    f = f + expect("part 1 present", p1 > 0, f"part1={p1}");
    f = f + expect("part 2 present", p2 > 0, f"part2={p2}");

    // Two different methods for each part.
    f = f + expect("part 1: walk == reverse", p1 == p1b, f"{p1} vs {p1b}");
    f = f + expect("part 2: per-click == closed form", p2 == p2b, f"{p2} vs {p2b}");

    // Decomposition: every hit is either a rotation's end (part 1's count)
    // or strictly inside a rotation.
    f = f + expect("part 2 == part 1 + inside", p2 == p1 + inside,
                   f"{p2} == {p1} + {inside}");

    // Forward walk vs. the exact signed sum, one modulus instead of n.
    let tot = total_delta(r);
    f = f + expect("final position == wrap(START + sum)", pos == wrap(START + tot),
                   f"{pos} == {wrap(START + tot)} (sum {tot})");

    // Bounds, all of them from outside the counting code.
    f = f + expect("part 1 <= rotations", p1 <= n, f"{p1} <= {n}");
    f = f + expect("part 2 <= clicks", p2 <= clicks, f"{p2} <= {clicks}");
    f = f + expect("part 1 <= part 2", p1 <= p2, f"{p1} <= {p2}");
    f = f + expect("final position in 0..99", pos >= 0 && pos < MOD, f"{pos}");

    print(f"real input: part 1 = {p1}, part 2 = {p2}, final = {pos}");
    f
}

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    let f = check_micro();

    let ex = check_hits_exhaustive();
    f = f + expect("hits_in == click-by-click, exhaustive",
                   ex == 0,
                   f"2 directions x 100 positions x 201 distances, {ex} mismatches");
    let pe = check_periodicity();
    f = f + expect("hits_in gains exactly 1 per revolution",
                   pe == 0,
                   f"2 directions x 100 positions x 201 distances, {pe} mismatches");

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

// ── the answer ────────────────────────────────────────────────────────────────

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day01: cannot read " + path + "\n");
        return 1;
    };
    let bad = first_bad(lines!);
    if (bad != 0) {
        eputs("day01: " + path + " line " + tostring(bad) + ": " + bad_reason(lines![bad - 1]) + "\n");
        return 1;
    };
    // An empty file is a wrong file, not an answer of 0: the statement
    // guarantees a sequence of rotations, so refuse rather than print 0.
    if (len(lines!) == 0) {
        eputs("day01: " + path + " holds no rotations\n");
        return 1;
    };
    let r = parse_lines(lines!);
    print("day01: Advent of Code 2025 day 1 -- Secret Entrance");
    print(f"input: {path}");
    print(f"rotations: {len(r.dirs)}");
    print(f"total clicks: {total_clicks(r)}");
    print(f"part 1 (rotations leaving the dial at 0): {part1_walk(r)}");
    print(f"part 2 (clicks leaving the dial at 0): {part2_per_click(r)}");
    print(f"final dial position: {final_walk(r)}");
    0
}

const HELP = "day01 -- Advent of Code 2025 day 1 (Secret Entrance), in Y

usage:
  ./day01 [FILE]        solve FILE (default input.txt) and print both answers
  ./day01 --check       run the property battery and print every assertion
  ./day01 --help        this text

part 1: how many rotations leave the dial pointing at 0
part 2: how many individual clicks leave it pointing at 0
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
                eputs("day01: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day01: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day01: more than one input file given (try --help)\n");
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