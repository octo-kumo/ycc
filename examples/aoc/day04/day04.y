// day04.y -- Advent of Code 2025, day 4 ("Printing Department"), in Y.
//
// A diagram of large rolls of paper: '@' is a roll, '.' is bare floor.  A
// forklift can reach a roll when there are FEWER THAN FOUR rolls in the eight
// adjacent positions (positions off the edge of the diagram are bare floor,
// not rolls).
//
//   part 1  how many rolls a forklift can reach in the diagram as given
//   part 2  take every reachable roll away at once; that may make more rolls
//           reachable, so repeat until nothing is reachable.  How many rolls
//           were taken away in total?
//
// Part 1 is computed twice (a direct per-cell count, and one pass that
// propagates neighbour counts outwards) and part 2 three times: a literal
// round-by-round rescan, an incremental peel that never rescans, and a
// certificate that proves the answer from the round labels alone.  `--check`
// runs the property battery; see README.md.
//
// build: ../../../refs/ycc.ref day04.y -o day04
// run:   ./day04                 (input.txt -> both answers)
//        ./day04 --check         (property check, no reference file)
//        ./day04 --help
import fs;

const CH_ROLL = 64;              // '@'
const CH_EMPTY = 46;             // '.'
const CH_NL = 10;
const CH_CR = 13;
const MIN_SIDE = 1;
const MAX_SIDE = 4096;

// The eight neighbour offsets -- up, down, left, right, then the four
// diagonals -- so the orthogonal four come first and D_FOUR can stop after
// them.  Module level: a literal inside a loop body would allocate per
// iteration and the heap is an arena.
const DY: [long] = [-1, 1, 0, 0, -1, -1, 1, 1];
const DX: [long] = [0, 0, -1, 1, -1, 1, -1, 1];

// ── injected defects ──────────────────────────────────────────────────────────
// One constant per deliberately wrong variant of the rules, used only by
// check_defects() in the property battery.  The solve path always passes
// D_NONE; there is no way to reach these from the command line.
const D_NONE = 0;                // the rules as the statement states them
const D_LE = 1;                  // "four or fewer" instead of "fewer than four"
const D_GE = 2;                  // inverted: open when there are 4 or MORE
const D_SELF = 3;                // the roll counts itself as one of the eight
const D_FOUR = 4;                // orthogonal neighbours only, no diagonals
const D_EDGE = 5;                // off the edge of the diagram counts as rolls
const D_WRAP = 6;                // wraps round instead of bounds-checking
const D_LOOP = 7;                // off-by-one loop bound: last column unread
const D_ASYNC = 8;               // removes during the scan, not simultaneously
const D_ONCE = 9;                // stops after the first round
const D_LAST = 10;               // counts only the final round
const D_NOOP = 11;               // removes nothing: part 2 collapses to part 1
const D_LABEL = 12;              // tells the truth about the total, lies about
                                 // the rounds: every removal claimed for round 1
const NDEFECTS = 12;

// A peel can never take more rounds than it has rolls; this is only a guard
// against a defect spinning forever.
const ROUND_LIMIT = 200000;

// What a parsed diagram is: `cells[y * w + x]` is 1 for a roll, 0 for floor.
type Grid = { w: long, h: long, rolls: long, cells: [long] };

// What a peel found: the total taken away, how many per round, how many were
// left, and label[cell] = the round that cell was taken in (0 = never).
type Peel = { total: long, rounds: [long], left: long, label: [long] };

// What the certificate proved: `bad` illegal steps (must be 0), `checked`
// removals it accounted for, and `surv` survivors.
type Cert = { bad: long, checked: long, surv: long };

// What an independent byte-level rescan of the same file saw.
type Scan = { w: long, h: long, rolls: long, bad: long, why: str };

// --check bookkeeping.  Globals, not captures, so every assert can tally.
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

// ── the rules ─────────────────────────────────────────────────────────────────

// Is a roll with `count` rolls around it reachable by a forklift?
def is_open(count: long, defect: long) -> bool {
    if (defect == D_LE) {
        count <= 4
    } else if (defect == D_GE) {
        count >= 4
    } else {
        count < 4
    }
}

// Rolls in the eight adjacent positions of (x, y).  `defect` selects one of
// the injected misreadings; D_NONE is the statement's rule.
def nb_count(g: [long], w: long, h: long, x: long, y: long, defect: long) -> long {
    let c = 0;
    let top = 8;
    if (defect == D_FOUR) { top = 4 };
    let k = 0;
    while (k < top) {
        let yy = y + DY[k];
        let xx = x + DX[k];
        let on = false;
        if (defect == D_EDGE) {
            if (yy < 0 || yy >= h || xx < 0 || xx >= w) {
                on = true;
            } else {
                on = g[yy * w + xx] == 1;
            };
        } else if (defect == D_WRAP) {
            let wy = yy;
            if (wy < 0) { wy = wy + h } else { if (wy >= h) { wy = wy - h } };
            let wx = xx;
            if (wx < 0) { wx = wx + w } else { if (wx >= w) { wx = wx - w } };
            on = g[wy * w + wx] == 1;
        } else {
            if (yy >= 0 && yy < h && xx >= 0 && xx < w) {
                on = g[yy * w + xx] == 1;
            };
        };
        if (on) { c = c + 1 };
        k = k + 1;
    };
    if (defect == D_SELF) { c = c + 1 };
    c
}

// Rolls in the eight adjacent positions of cell `i`, counted over an explicit
// presence array.  Deliberately a different function from nb_count: it is the
// certificate's own arithmetic, with no defect branches at all.
def nb_live(live: [long], w: long, h: long, x: long, y: long) -> long {
    let c = 0;
    let k = 0;
    while (k < 8) {
        let yy = y + DY[k];
        let xx = x + DX[k];
        if (yy >= 0 && yy < h && xx >= 0 && xx < w) {
            if (live[yy * w + xx] == 1) { c = c + 1 };
        };
        k = k + 1;
    };
    c
}

// Neighbour counts for every cell, by propagating one outwards from each roll.
// Used by part 1's second method and by the incremental peel.
def neighbour_counts(g: [long], w: long, h: long) -> [long] {
    let n = w * h;
    let deg: [long] = [];
    let i = 0;
    while (i < n) { deg += 0; i = i + 1 };
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            if (g[y * w + x] == 1) {
                let k = 0;
                while (k < 8) {
                    let yy = y + DY[k];
                    let xx = x + DX[k];
                    if (yy >= 0 && yy < h && xx >= 0 && xx < w) {
                        let idx = yy * w + xx;
                        deg[idx] = deg[idx] + 1;
                    };
                    k = k + 1;
                };
            };
            x = x + 1;
        };
        y = y + 1;
    };
    deg
}

// ── part 1 ────────────────────────────────────────────────────────────────────

// Method A: look at each roll and count its eight neighbours on the spot.
// Straight from the statement, and the yardstick the other methods are held to.
def part1_direct(g: [long], w: long, h: long, defect: long) -> long {
    let n = 0;
    let xmax = w;
    if (defect == D_LOOP) { xmax = w - 1 };
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < xmax) {
            if (g[y * w + x] == 1) {
                if (is_open(nb_count(g, w, h, x, y, defect), defect)) { n = n + 1 };
            };
            x = x + 1;
        };
        y = y + 1;
    };
    n
}

// Method B: build every cell's neighbour count in one outward pass, then read
// the answers off it.  A different accumulation order, and no predicate call
// per cell -- so it fails differently from method A.  Never defective.
def part1_propagated(g: [long], w: long, h: long) -> long {
    let deg = neighbour_counts(g, w, h);
    let n = 0;
    let i = 0;
    while (i < w * h) {
        if (g[i] == 1 && deg[i] < 4) { n = n + 1 };
        i = i + 1;
    };
    n
}

// ── part 2 ────────────────────────────────────────────────────────────────────

// Method A: the statement's own shape.  Every round, scan the whole diagram
// and take away every roll that is open AT THE START of the round.  Nothing is
// ever recomputed incrementally, and no roll is taken away until the scan of
// its round has finished -- that simultaneity is the whole subtlety.
def part2_rounds(g: [long], w: long, h: long, defect: long) -> Peel {
    let n = w * h;
    let live: [long] = [];
    let label: [long] = [];
    let acc: [long] = [];
    let i = 0;
    while (i < n) { live += g[i]; label += 0; acc += 0; i = i + 1 };

    let rounds: [long] = [];
    let total = 0;
    let held = 0;
    let xmax = w;
    if (defect == D_LOOP) { xmax = w - 1 };
    let done = false;
    let round = 0;
    while (!done) {
        round = round + 1;
        let nacc = 0;
        let y = 0;
        while (y < h) {
            let x = 0;
            while (x < xmax) {
                let idx = y * w + x;
                if (live[idx] == 1) {
                    if (is_open(nb_count(live, w, h, x, y, defect), defect)) {
                        acc[nacc] = idx;
                        nacc = nacc + 1;
                        if (defect == D_ASYNC) { live[idx] = 0 };
                    };
                };
                x = x + 1;
            };
            y = y + 1;
        };
        if (nacc == 0) {
            if (defect == D_LAST) {
                total = total + held;
                rounds += held;
            };
            done = true;
        } else {
            if (defect == D_ASYNC) {
                let t = 0;
                while (t < nacc) { live[acc[t]] = 0; t = t + 1 };
            } else {
                let t = 0;
                while (t < nacc) {
                    let idx = acc[t];
                    live[idx] = 0;
                    if (defect == D_LABEL) { label[idx] = 1 } else { label[idx] = round };
                    t = t + 1;
                };
            };
            held = nacc;
            if (defect == D_ONCE) {
                total = total + nacc;
                rounds += nacc;
                done = true;
            } else if (defect == D_NOOP) {
                total = total + nacc;
                rounds += nacc;
                done = true;
            } else {
                total = total + nacc;
                rounds += nacc;
            };
        };
        if (round >= ROUND_LIMIT) { done = true };
    };
    let left = 0;
    i = 0;
    while (i < n) {
        if (live[i] == 1) { left = left + 1 };
        i = i + 1;
    };
    { total: total, rounds: rounds, left: left, label: label }
}

// Method B: the same answer reached without ever rescanning.  The neighbour
// counts are maintained as rolls go away -- removing a roll can only lower a
// neighbour's count, so each cell's count is decremented at most 8 times over
// the whole run and the peel costs O(rolls * 8) instead of O(rounds * cells).
// Never defective, so it is the honest second opinion on method A.
def part2_incremental(g: [long], w: long, h: long) -> Peel {
    let n = w * h;
    let live: [long] = [];
    let acc: [long] = [];
    let i = 0;
    while (i < n) { live += g[i]; acc += 0; i = i + 1 };
    let deg = neighbour_counts(live, w, h);

    let rounds: [long] = [];
    let total = 0;
    let done = false;
    let round = 0;
    while (!done) {
        round = round + 1;
        let nacc = 0;
        let idx = 0;
        while (idx < n) {
            if (live[idx] == 1 && deg[idx] < 4) {
                acc[nacc] = idx;
                nacc = nacc + 1;
            };
            idx = idx + 1;
        };
        if (nacc == 0) {
            done = true;
        } else {
            let t = 0;
            while (t < nacc) {
                let cell = acc[t];
                live[cell] = 0;
                let x = cell % w;
                let y = cell / w;
                let k = 0;
                while (k < 8) {
                    let yy = y + DY[k];
                    let xx = x + DX[k];
                    if (yy >= 0 && yy < h && xx >= 0 && xx < w) {
                        let j = yy * w + xx;
                        if (live[j] == 1) { deg[j] = deg[j] - 1 };
                    };
                    k = k + 1;
                };
                t = t + 1;
            };
            total = total + nacc;
            rounds += nacc;
        };
        if (round >= ROUND_LIMIT) { done = true };
    };
    let left = 0;
    i = 0;
    while (i < n) {
        if (live[i] == 1) { left = left + 1 };
        i = i + 1;
    };
    { total: total, rounds: rounds, left: left, label: [] }
}

// ── the certificate ───────────────────────────────────────────────────────────

// Prove a peel from its round labels alone, never re-running a peel.
//
// Step back through the rounds.  Just before round t the rolls still standing
// are the survivors plus everything taken in rounds t, t+1, ...; every roll
// taken in round t must then have had FEWER THAN FOUR neighbours among them.
// After the last round the survivors must all have FOUR OR MORE neighbours
// among the survivors, or the peel had not finished.
//
// The two together are a proof, not a rerun: the first half shows every
// removal was legal (so no more than this many could ever come away), the
// second shows the end state admits no further removal (so no fewer could).
def certify(g: [long], w: long, h: long, label: [long], nrounds: long) -> Cert {
    let n = w * h;
    let stand: [long] = [];
    let i = 0;
    while (i < n) {
        if (g[i] == 1 && label[i] == 0) { stand += 1 } else { stand += 0 };
        i = i + 1;
    };
    let bad = 0;
    let checked = 0;
    let t = nrounds;
    while (t >= 1) {
        // the rolls taken in round t were still standing when round t opened
        i = 0;
        while (i < n) {
            if (g[i] == 1 && label[i] == t) { stand[i] = 1 };
            i = i + 1;
        };
        i = 0;
        while (i < n) {
            if (g[i] == 1 && label[i] == t) {
                let c = nb_live(stand, w, h, i % w, i / w);
                if (c >= 4) { bad = bad + 1 };
                checked = checked + 1;
                stand[i] = 0;
            };
            i = i + 1;
        };
        t = t - 1;
    };
    let surv = 0;
    i = 0;
    while (i < n) {
        if (stand[i] == 1) {
            surv = surv + 1;
            let c = nb_live(stand, w, h, i % w, i / w);
            if (c < 4) { bad = bad + 1 };
        };
        i = i + 1;
    };
    { bad: bad, checked: checked, surv: surv }
}

// ── parsing ───────────────────────────────────────────────────────────────────

// "" when `line` is a row of the diagram, otherwise why it is not.  The
// statement guarantees a rectangle of '@' and '.'; anything else is a parse
// failure we report rather than quietly count as bare floor.
def bad_row(line: str) -> str {
    let k = 0;
    while (k < line.length) {
        let c = line[k];
        if (c != CH_ROLL && c != CH_EMPTY) {
            return "unexpected byte " + tostring(c) + " at column " + tostring(k + 1);
        };
        k = k + 1;
    };
    ""
}

def parse_rows(rows: [str]) -> Grid {
    let n = len(rows);
    let w = 0;
    let h = 0;
    let rolls = 0;
    let i = 0;
    while (i < n) {
        let line = rows[i];
        // A trailing newline can leave one empty string behind; a row of the
        // diagram always has at least one byte, so an empty one is not a row.
        if (line.length > 0) {
            h = h + 1;
            if (line.length > w) { w = line.length };
            let k = 0;
            while (k < line.length) {
                if (line[k] == CH_ROLL) { rolls = rolls + 1 };
                k = k + 1;
            };
        };
        i = i + 1;
    };
    // A short row reads as bare floor to the right, so the diagram is a
    // rectangle `w` wide however ragged the rows were.
    let cells: [long] = [];
    i = 0;
    while (i < n) {
        let line = rows[i];
        if (line.length > 0) {
            let k = 0;
            while (k < w) {
                if (k < line.length && line[k] == CH_ROLL) { cells += 1 } else { cells += 0 };
                k = k + 1;
            };
        };
        i = i + 1;
    };
    { w: w, h: h, rolls: rolls, cells: cells }
}

// An independent second read of the file: walk the raw bytes, count rows,
// widths and rolls, and reject anything that is not '.' or '@'.  Nothing here
// goes through fs.read_lines() or parse_rows(), so agreeing with them means
// two unrelated readers saw the same file.
def rescan(b: [byte]) -> Scan {
    let w = 0;
    let h = 0;
    let rolls = 0;
    let bad = 0;
    let why = "";
    let col = 0;
    let i = 0;
    while (i < len(b)) {
        let c = b[i];
        if (c == CH_NL) {
            if (col > 0) {
                h = h + 1;
                if (col > w) { w = col };
                col = 0;
            };
        } else if (c == CH_CR) {
            0                                     // tolerated, ignored
        } else {
            col = col + 1;
            if (c == CH_ROLL) {
                rolls = rolls + 1;
            } else if (c == CH_EMPTY) {
                0
            } else {
                bad = bad + 1;
                if (why == "") { why = "byte " + tostring(c) + " at offset " + tostring(i) };
            };
        };
        i = i + 1;
    };
    if (col > 0) {                              // no final newline
        h = h + 1;
        if (col > w) { w = col };
    };
    { w: w, h: h, rolls: rolls, bad: bad, why: why }
}

// ── the check harness ─────────────────────────────────────────────────────────

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

// Same, but for the tally lines the battery prints at the end: quiet unless
// something went wrong.
def note(name: str, ok: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    let bad = 0;
    if (!ok) {
        checks_failed = checks_failed + 1;
        bad = 1;
        if (first_failure == "") { first_failure = name };
        print("FAIL " + name + "   " + detail);
    };
    bad
}

def rounds_to_str(rs: [long], want: long) -> str {
    let s = "";
    let n = len(rs);
    if (n < want) { want = n };
    let i = 0;
    while (i < want) {
        if (i > 0) { s += " " };
        s += tostring(rs[i]);
        i = i + 1;
    };
    s
}

def sum_of(rs: [long]) -> long {
    let s = 0;
    let i = 0;
    while (i < len(rs)) { s = s + rs[i]; i = i + 1 };
    s
}

// The same, for a list of names.
def names_to_str(xs: [str], want: long) -> str {
    let s = "";
    let n = len(xs);
    if (n < want) { want = n };
    let i = 0;
    while (i < want) {
        if (i > 0) { s += ", " };
        s += xs[i];
        i = i + 1;
    };
    s
}

// The grids the hand arithmetic in README.md is written out for.  Every row is
// kept literal and at module/function scope only: nothing here is built inside
// a loop.
type Case = { name: str, rows: [str], rolls: long, p1: long, p2: long, rounds: str };

def micro_cases() -> [Case] {
    [
    { name: "A single roll", rows: ["@"],
      rolls: 1, p1: 1, p2: 1, rounds: "1" },
    { name: "B 2x2 block", rows: ["@@", "@@"],
      rolls: 4, p1: 4, p2: 4, rounds: "4" },
    { name: "C 3x3 block", rows: ["@@@", "@@@", "@@@"],
      rolls: 9, p1: 4, p2: 9, rounds: "4 4 1" },
    { name: "D 4x4 block", rows: ["@@@@", "@@@@", "@@@@", "@@@@"],
      rolls: 16, p1: 4, p2: 4, rounds: "4" },
    { name: "E plus 5x5", rows: ["..@..", "..@..", "@@@@@", "..@..", "..@.."],
      rolls: 9, p1: 4, p2: 9, rounds: "4 4 1" },
    { name: "F 1x5 row", rows: ["@@@@@"],
      rolls: 5, p1: 5, p2: 5, rounds: "5" },
    { name: "G 2x5 block", rows: ["@@@@@", "@@@@@"],
      rolls: 10, p1: 4, p2: 10, rounds: "4 4 2" },
    { name: "H ring 5x5", rows: ["@@@@@", "@...@", "@...@", "@...@", "@@@@@"],
      rolls: 16, p1: 16, p2: 16, rounds: "16" },
    { name: "I nothing reachable", rows: [".@@.", "@@@@", "@@@@", ".@@."],
      rolls: 12, p1: 0, p2: 0, rounds: "" },
    ]
}

// The statement's own worked example, verbatim from the puzzle page, with the
// two anchors: part 1's 13 is printed in the statement, part 2's 43 is the
// value public write-ups report for it (README.md names them).
const EXAMPLE_ROWS: [str] = ["..@@.@@@@.",
                             "@@@.@.@.@@",
                             "@@@@@.@.@@",
                             "@.@@@@..@.",
                             "@@.@@@@.@@",
                             ".@@@@@@@.@",
                             ".@.@.@.@@@",
                             "@.@@@.@@@@",
                             ".@@@@@@@@.",
                             "@.@.@@@.@."];
const EXAMPLE_P1 = 13;
const EXAMPLE_P2 = 43;

// Run one grid through the whole pipeline: four counters that must agree, the
// certificate, and the invariants.  Returns the number of failures.
def check_one(name: str, g: Grid, want1: long, want2: long, want_rounds: str,
              quiet: bool) -> long {
    let f = 0;
    let rolls = g.rolls;
    let p1 = part1_direct(g.cells, g.w, g.h, D_NONE);
    let p1b = part1_propagated(g.cells, g.w, g.h);
    let pr = part2_rounds(g.cells, g.w, g.h, D_NONE);
    let pi = part2_incremental(g.cells, g.w, g.h);
    let nr = len(pr.rounds);
    let ct = certify(g.cells, g.w, g.h, pr.label, nr);

    let rs = rounds_to_str(pr.rounds, 12);
    let detail = f"{g.w}x{g.h} rolls={rolls} part1={p1}/{p1b} part2={pr.total}/{pi.total}"
                 + f" left={pr.left}/{pi.left} rounds=[{rs}] cert bad={ct.bad}"
                 + f" checked={ct.checked} surv={ct.surv}";
    if (!quiet) { print("  " + name + ": " + detail) };

    // Presence guards: never compare two numbers that might both be absent.
    // Case I below legitimately has 0 rolls reachable, so "non-zero" cannot be
    // asserted of the answers in general -- but they must be PRESENT, and the
    // number of cells and rolls must be non-zero on a real diagram.
    f = f + note(name + " [cells present]",
                 g.w > 0 && g.h > 0 && len(g.cells) == g.w * g.h,
                 f"w={g.w} h={g.h} cells={len(g.cells)}");
    f = f + note(name + " [rolls present]", rolls > 0 && rolls <= g.w * g.h, f"{rolls}");

    // The hand arithmetic of README.md, or the published anchors.
    f = f + note(name + " [part 1]", p1 == want1 && p1b == want1, f"got {p1}/{p1b} want {want1}");
    f = f + note(name + " [part 2]", pr.total == want2 && pi.total == want2,
                 f"got {pr.total}/{pi.total} want {want2}");
    if (!quiet || want2 != 0) {
        f = f + note(name + " [rounds]", rounds_to_str(pr.rounds, 64) == want_rounds,
                     f"got [{rs}] want [{want_rounds}]");
    };

    // Two methods for each part.
    f = f + note(name + " [part 1: direct == propagated]", p1 == p1b, f"{p1} vs {p1b}");
    f = f + note(name + " [part 2: rescan == incremental]",
                 pr.total == pi.total && pr.left == pi.left, f"{pr.total}/{pr.left} vs {pi.total}/{pi.left}");
    f = f + note(name + " [part 2: round vectors equal]",
                 rounds_to_str(pr.rounds, 64) == rounds_to_str(pi.rounds, 64),
                 f"[{rs}] vs [{rounds_to_str(pi.rounds, 12)}]");

    // Invariants.
    f = f + note(name + " [0 <= part 1]", p1 >= 0, f"{p1}");
    f = f + note(name + " [part 1 <= part 2]", p1 <= pr.total, f"{p1} <= {pr.total}");
    f = f + note(name + " [part 2 <= rolls]", pr.total <= rolls, f"{pr.total} <= {rolls}");
    f = f + note(name + " [rounds sum to part 2]", sum_of(pr.rounds) == pr.total,
                 f"{sum_of(pr.rounds)} vs {pr.total}");
    f = f + note(name + " [part 2 == rolls - left]", pr.total == rolls - pr.left,
                 f"{pr.total} == {rolls} - {pr.left}");
    f = f + note(name + " [a round removes at least one roll]",
                 nr == 0 || pr.rounds[0] > 0, f"{nr} rounds");

    // The certificate: every removal legal, and the survivors all have four or
    // more neighbours among themselves.  `checked` must account for exactly the
    // rolls that were taken away, or the proof has not covered them all.
    f = f + note(name + " [certificate]", ct.bad == 0 && ct.checked == pr.total,
                 f"bad={ct.bad} checked={ct.checked} of {pr.total}");
    f = f + note(name + " [certificate survivors]", ct.surv == pr.left,
                 f"{ct.surv} vs {pr.left}");

    // The peel must actually terminate: no round list longer than the rolls.
    f = f + note(name + " [rounds bounded by rolls]", nr <= rolls, f"{nr} <= {rolls}");
    f
}

def check_micro() -> long {
    let f = 0;
    let cs = micro_cases();
    let i = 0;
    while (i < len(cs)) {
        let c = cs[i];
        let g = parse_rows(c.rows);
        f = f + check_one("micro " + c.name, g, c.p1, c.p2, c.rounds, false);
        i = i + 1;
    };
    f
}

def check_example() -> long {
    let g = parse_rows(EXAMPLE_ROWS);
    let f = 0;
    f = f + expect("example [part 1 = 13, from the statement]",
                   part1_direct(g.cells, g.w, g.h, D_NONE) == EXAMPLE_P1
                   && part1_propagated(g.cells, g.w, g.h) == EXAMPLE_P1,
                   f"part 1 = {part1_direct(g.cells, g.w, g.h, D_NONE)}");
    f = f + expect("example [part 2 = 43, from the public write-ups]",
                   part2_rounds(g.cells, g.w, g.h, D_NONE).total == EXAMPLE_P2
                   && part2_incremental(g.cells, g.w, g.h).total == EXAMPLE_P2,
                   f"part 2 = {part2_rounds(g.cells, g.w, g.h, D_NONE).total}");
    f = f + check_one("example", g, EXAMPLE_P1, EXAMPLE_P2,
                      "13 12 7 5 2 1 1 1 1", false);
    f
}

// ── exhaustive agreement ──────────────────────────────────────────────────────

// 2^n, by repeated doubling: `[0; n]` wants a literal and `<<` on a long is
// there, but doubling keeps the intent obvious at a glance.
def pow2(n: long) -> long {
    let v = 1;
    let k = 0;
    while (k < n) { v = v * 2; k = k + 1 };
    v
}

// Every non-empty `h` x `w` diagram with both bits set, run through both
// methods for both parts plus the certificate.  `want_cases` is 2^(w*h) - 1
// written out by hand -- an expectation from outside the code under test, so a
// sweep that quietly covered the wrong number of diagrams cannot pass.  The
// certificate runs at 4x3 (4095 diagrams) and at 4x4 (65535); 4x4 does every
// other assertion too.  `want_survivors` says whether a diagram this small can
// have a roll survive the cascade at all: none below 4x4 can, so demanding one
// there would fail for the wrong reason.
def check_exhaustive(w: long, h: long, with_cert: bool, want_survivors: bool,
                     want_cases: long) -> long {
    let n = w * h;
    let cases = want_cases;
    let cells: [long] = [];
    let i = 0;
    while (i < n) { cells += 0; i = i + 1 };

    let seen = 0;
    let methods_bad = 0;
    let inv_bad = 0;
    let cert_bad = 0;
    let nonzero_p1 = 0;
    let lone_p1 = 0;
    let all_reachable = 0;
    let with_survivors = 0;
    let d1: [long] = [];                          // the part-1 totals that occurred
    let d2: [long] = [];                          // and the part-2 totals
    let mask = 1;
    while (mask <= cases) {
        i = 0;
        let rolls = 0;
        while (i < n) {
            let bit = (mask >> i) & 1;            // >> is arithmetic; mask >= 0
            cells[i] = bit;
            rolls = rolls + bit;
            i = i + 1;
        };
        seen = seen + 1;
        let p1 = part1_direct(cells, w, h, D_NONE);
        let p1b = part1_propagated(cells, w, h);
        let pr = part2_rounds(cells, w, h, D_NONE);
        let pi = part2_incremental(cells, w, h);
        if (p1 != p1b || pr.total != pi.total || pr.left != pi.left
            || rounds_to_str(pr.rounds, 64) != rounds_to_str(pi.rounds, 64)) {
            methods_bad = methods_bad + 1;
        };
        if (!(p1 >= 0 && p1 <= pr.total && pr.total <= rolls
              && sum_of(pr.rounds) == pr.total
              && pr.total == rolls - pr.left
              && (len(pr.rounds) == 0 || pr.rounds[0] > 0)
              && len(pr.rounds) <= rolls)) {
            inv_bad = inv_bad + 1;
        };
        if (p1 > 0) { nonzero_p1 = nonzero_p1 + 1 };
        if (p1 == 1) { lone_p1 = lone_p1 + 1 };
        if (pr.total == rolls) { all_reachable = all_reachable + 1 };
        if (pr.left > 0) { with_survivors = with_survivors + 1 };
        mark(d1, p1);
        mark(d2, pr.total);
        if (with_cert) {
            let ct = certify(cells, w, h, pr.label, len(pr.rounds));
            if (ct.bad != 0 || ct.checked != pr.total || ct.surv != pr.left) {
                cert_bad = cert_bad + 1;
            };
        };
        mask = mask + 1;
    };
    let label = tostring(w) + "x" + tostring(h);
    let f = 0;
    // The sweep itself has to be complete, or "0 disagreements" means nothing.
    f = f + expect("exhaustive " + label + ": sweep is complete",
                   seen == cases && cases == pow2(n) - 1,
                   f"{seen} diagrams, expected {cases}");
    f = f + expect("exhaustive " + label + ": methods agree", methods_bad == 0,
                   f"{cases} non-empty diagrams, {methods_bad} disagreements");
    f = f + expect("exhaustive " + label + ": invariants hold", inv_bad == 0,
                   f"{cases} non-empty diagrams, {inv_bad} violations");
    if (with_cert) {
        f = f + expect("exhaustive " + label + ": certificate proves every peel",
                       cert_bad == 0, f"{cases} non-empty diagrams, {cert_bad} unproved");
    };
    // Guard against a vacuous pass: a sweep stuck on one number would agree with
    // itself forever.  It has to have seen a spread of part-1 and part-2 totals,
    // a diagram with a single reachable roll, a diagram where every roll comes
    // away, and -- where one can exist -- a diagram where rolls survive.
    let spread_ok = len(d1) >= 3 && len(d2) >= 3 && nonzero_p1 > 0 && lone_p1 > 0
                    && all_reachable > 0;
    if (want_survivors) { spread_ok = spread_ok && with_survivors > 0 };
    f = f + expect("exhaustive " + label + ": sweep is not vacuous", spread_ok,
                   f"{len(d1)} distinct part 1, {len(d2)} distinct part 2,"
                   + f" {nonzero_p1} with part 1 > 0, {lone_p1} with part 1 == 1,"
                   + f" {all_reachable} fully peeled, {with_survivors} with survivors"
                   + f", of {cases}");
    f
}

// Record `v` in the (tiny, short) list of distinct values seen.
def mark(xs: [long], v: long) -> long {
    let i = 0;
    let found = false;
    while (i < len(xs)) {
        if (xs[i] == v) { found = true };
        i = i + 1;
    };
    if (!found) { xs += v };
    len(xs)
}

// ── the real input ────────────────────────────────────────────────────────────

def check_real(path: str) -> long {
    let f = 0;
    let bytes: [byte]? = fs.read_bytes(path);
    let rows: [str]? = fs.read_lines(path);
    if (bytes == none || rows == none) {
        f = f + expect("input.txt present", false, "cannot read " + path);
        return f;
    };
    f = f + expect("input.txt present", true,
                   f"{len(rows!)} lines, {len(bytes!)} bytes");

    // Validate every row before trusting any of them.
    let badat = 0;
    let i = 0;
    while (i < len(rows!)) {
        if (badat == 0 && bad_row(rows![i]) != "") { badat = i + 1 };
        i = i + 1;
    };
    if (badat != 0) {
        f = f + expect("input well formed", false,
                       "line " + tostring(badat) + ": " + bad_row(rows![badat - 1]));
        return f;
    };
    f = f + expect("input well formed", true, f"{len(rows!)} lines, all '.' and '@'");

    let g = parse_rows(rows!);
    let sc = rescan(bytes!);
    if (g.w < MIN_SIDE || g.h < MIN_SIDE || g.w > MAX_SIDE || g.h > MAX_SIDE) {
        f = f + expect("input shape sane", false, f"{g.w}x{g.h} rows {g.h}");
        return f;
    };
    f = f + expect("input shape sane", true, f"{g.w} x {g.h}");

    // Presence guards, before anything is compared.
    f = f + expect("rolls present", g.rolls > 0, f"{g.rolls} rolls");
    f = f + expect("rescan present", sc.rolls > 0 && sc.w > 0 && sc.h > 0,
                   f"{sc.w}x{sc.h} rolls={sc.rolls}");

    // The parser and the independent byte scan must agree.
    f = f + expect("parse == rescan",
                   sc.rolls == g.rolls && sc.w == g.w && sc.h == g.h && sc.bad == 0,
                   f"{sc.w}x{sc.h}/{sc.rolls} vs {g.w}x{g.h}/{g.rolls}");

    // The anchors, run on the statement's own example, through the shipped
    // solve path -- not through the check-only helpers.
    let ex = parse_rows(EXAMPLE_ROWS);
    let ex1 = solve_part1(ex);
    let ex2 = solve_part2(ex);
    f = f + expect("anchor part 1 == 13 (statement)", ex1 == EXAMPLE_P1, f"{ex1}");
    f = f + expect("anchor part 2 == 43 (write-ups)", ex2 == EXAMPLE_P2, f"{ex2}");

    let p1 = solve_part1(g);
    let p2 = solve_part2(g);
    f = f + expect("part 1 present", p1 > 0, f"{p1}");
    f = f + expect("part 2 present", p2 > 0, f"{p2}");

    // The invariant that makes a zero suspicious rather than plausible: a peel
    // that starts must go on, and every removal is proved legal below.
    let pr = part2_rounds(g.cells, g.w, g.h, D_NONE);
    f = f + expect("part 2 >= part 1", p2 >= p1, f"{p2} >= {p1}");
    f = f + expect("part 2 == rolls - left", p2 == g.rolls - pr.left,
                   f"{p2} == {g.rolls} - {pr.left}");
    f = f + check_one("real input", g, p1, p2,
                      rounds_to_str(pr.rounds, 64), true);

    print(f"real input: {g.w}x{g.h}, {g.rolls} rolls, part 1 = {p1}, part 2 = {p2},"
          + f" {pr.left} left after {len(pr.rounds)} rounds");
    f
}

// ── defect injection ──────────────────────────────────────────────────────────

// Run the shipped pipeline with one injected defect and report what it said.
// Every defect must disagree with the truth on at least one of the micro-cases
// or the example, or fail the certificate: a check that a wrong solver can
// pass is not a check.
def check_defects() -> long {
    let cs = micro_cases();
    // truth for every grid the defects are run against, from the honest path
    let truth_p1: [long] = [];
    let truth_p2: [long] = [];
    let truth_left: [long] = [];
    let truth_rounds: [str] = [];
    let i = 0;
    while (i < len(cs)) {
        let g = parse_rows(cs[i].rows);
        truth_p1 += part1_direct(g.cells, g.w, g.h, D_NONE);
        let pr = part2_rounds(g.cells, g.w, g.h, D_NONE);
        truth_p2 += pr.total;
        truth_left += pr.left;
        truth_rounds += rounds_to_str(pr.rounds, 64);
        i = i + 1;
    };
    let ge = parse_rows(EXAMPLE_ROWS);
    truth_p1 += part1_direct(ge.cells, ge.w, ge.h, D_NONE);
    let pe = part2_rounds(ge.cells, ge.w, ge.h, D_NONE);
    truth_p2 += pe.total;
    truth_left += pe.left;
    truth_rounds += rounds_to_str(pe.rounds, 64);

    let names: [str] = ["D_LE four-or-fewer", "D_GE inverted", "D_SELF counts itself",
                        "D_FOUR no diagonals", "D_EDGE off-grid counts", "D_WRAP wraps",
                        "D_LOOP last column unread", "D_ASYNC removes in the scan",
                        "D_ONCE first round only", "D_LAST last round only",
                        "D_NOOP removes nothing", "D_LABEL mislabels the rounds"];
    let caught_answer = 0;
    let caught_cert = 0;
    let missed: [str] = [];
    let d = 1;
    while (d <= NDEFECTS) {
        let wrong_here = 0;
        let cert_here = 0;
        let first_where = "";
        i = 0;
        while (i < len(cs)) {
            let g = parse_rows(cs[i].rows);
            let bad = run_defective(d, g, truth_p1[i], truth_p2[i], truth_left[i],
                                    truth_rounds[i]);
            if (bad) {
                wrong_here = wrong_here + 1;
                if (first_where == "") { first_where = cs[i].name };
            };
            if (certify_defective(d, g)) { cert_here = cert_here + 1 };
            i = i + 1;
        };
        // and on the statement's example
        let last = len(truth_p1) - 1;
        let bad = run_defective(d, ge, truth_p1[last], truth_p2[last], truth_left[last],
                                truth_rounds[last]);
        if (bad) {
            wrong_here = wrong_here + 1;
            if (first_where == "") { first_where = "example" };
        };
        if (certify_defective(d, ge)) { cert_here = cert_here + 1 };

        if (wrong_here > 0) { caught_answer = caught_answer + 1 };
        if (cert_here > 0) { caught_cert = caught_cert + 1 };
        if (wrong_here > 0 || cert_here > 0) {
            print(f"     caught {names[d - 1]}: wrong answer on {wrong_here} of"
                  + f" {len(cs) + 1} grids (first: {first_where}),"
                  + f" certificate rejects {cert_here}");
        } else {
            missed += names[d - 1];
        };
        d = d + 1;
    };
    let f = 0;
    f = f + expect("every injected defect is caught",
                   len(missed) == 0,
                   f"{caught_answer}/{NDEFECTS} wrong answers, {caught_cert}/{NDEFECTS}"
                   + f" certificate rejections"
                   + (if (len(missed) == 0) { "" } else { ", missed: " + names_to_str(missed, 8) }));
    f
}

// Did a defective run of part 1 + part 2 disagree with the truth?  The rounds
// taken off the table matter as much as the totals, so `left` and the round
// vector count too.  That matters for one defect in particular: removing rolls
// during the scan instead of simultaneously leaves the TOTAL unchanged (see
// README.md, "order independence"), so a check that only compared totals would
// be blind to it.
def run_defective(d: long, g: Grid, want1: long, want2: long, want_left: long,
                  want_rounds: str) -> bool {
    let p1 = part1_direct(g.cells, g.w, g.h, d);
    let pr = part2_rounds(g.cells, g.w, g.h, d);
    p1 != want1 || pr.total != want2 || pr.left != want_left
        || rounds_to_str(pr.rounds, 64) != want_rounds
}

// The certificate run on a defective peel.  D_ASYNC, D_LABEL and the
// early-exit defects leave `label` describing rounds that do not correspond to
// any real state, so they are checked against the round list as it came out --
// which is the point: the certificate must reject them.
def certify_defective(d: long, g: Grid) -> bool {
    let pr = part2_rounds(g.cells, g.w, g.h, d);
    let ct = certify(g.cells, g.w, g.h, pr.label, len(pr.rounds));
    ct.bad != 0 || ct.checked != pr.total || ct.surv != pr.left
}

// Order independence, asserted as a property rather than caught as a defect:
// peeling a whole scan's worth of rolls in scan order removes the SAME SET of
// rolls as peeling whole rounds, because both stop exactly at the 4-core (the
// largest set of rolls in which every roll has four or more neighbours).  So
// the TOTAL is invariant while the round vector is not.  A check that compared
// only totals would be blind to D_ASYNC; this says so out loud, and pins the
// round bookkeeping down at the same time.
def check_order_independence() -> long {
    let f = 0;
    let g = parse_rows(EXAMPLE_ROWS);
    let sync = part2_rounds(g.cells, g.w, g.h, D_NONE);
    let scan = part2_rounds(g.cells, g.w, g.h, D_ASYNC);
    f = f + expect("order independence: same total, different rounds",
                   scan.total == sync.total && scan.left == sync.left
                   && rounds_to_str(scan.rounds, 64) != rounds_to_str(sync.rounds, 64),
                   f"rounds [{rounds_to_str(scan.rounds, 64)}] = {scan.total},"
                   + f" scan order [{rounds_to_str(sync.rounds, 64)}] = {sync.total}");
    // And over the whole 4x3 state space: 2^12 - 1 = 4095 diagrams.
    let n = 12;
    let cases = 4095;
    let cells: [long] = [];
    let i = 0;
    while (i < n) { cells += 0; i = i + 1 };
    let bad = 0;
    let differ = 0;
    let seen = 0;
    let mask = 1;
    while (mask <= cases) {
        seen = seen + 1;
        i = 0;
        while (i < n) {
            let bit = (mask >> i) & 1;
            cells[i] = bit;
            i = i + 1;
        };
        let s = part2_rounds(cells, 4, 3, D_NONE);
        let a = part2_rounds(cells, 4, 3, D_ASYNC);
        if (s.total != a.total || s.left != a.left) { bad = bad + 1 };
        if (rounds_to_str(s.rounds, 64) != rounds_to_str(a.rounds, 64)) { differ = differ + 1 };
        mask = mask + 1;
    };
    f = f + expect("order independence: same total over all 4x3 diagrams",
                   bad == 0 && seen == cases,
                   f"{seen} diagrams, {bad} disagreements");
    f = f + expect("order independence: round vectors really do differ", differ > 0,
                   f"{differ} of {seen} diagrams split into different rounds");
    f
}

// ── the answer ────────────────────────────────────────────────────────────────

def solve_part1(g: Grid) -> long { part1_direct(g.cells, g.w, g.h, D_NONE) }
def solve_part2(g: Grid) -> long { part2_rounds(g.cells, g.w, g.h, D_NONE).total }

// `ycc`'s own heap counter, sampled around each phase, so the allocation claim
// in README.md is measured rather than eyeballed.  Opt-in (--heap): nothing in
// the deterministic run touches it.
def heap_report(path: str) -> long {
    let h0 = heap_used();
    let rows: [str]? = fs.read_lines(path);
    if (rows == none) {
        eputs("day04: cannot read " + path + "\n");
        return 1;
    };
    let h1 = heap_used();
    let g = parse_rows(rows!);
    let h2 = heap_used();
    let p1 = solve_part1(g);
    let h3 = heap_used();
    let pr = part2_rounds(g.cells, g.w, g.h, D_NONE);
    let h4 = heap_used();
    let pi = part2_incremental(g.cells, g.w, g.h);
    let h5 = heap_used();
    print(f"heap after start:                 {h0}");
    print(f"heap after read_lines:            {h1}  (+{h1 - h0})");
    print(f"heap after parse:                 {h2}  (+{h2 - h1})");
    print(f"heap after part 1:                {h3}  (+{h3 - h2})");
    print(f"heap after part 2 (rescan):       {h4}  (+{h4 - h3})");
    print(f"heap after part 2 (incremental):  {h5}  (+{h5 - h4})");
    print(f"part 1 = {p1}, part 2 = {pr.total} by rescan and {pi.total} by incremental");
    0
}

def solve(path: str) -> long {
    let rows: [str]? = fs.read_lines(path);
    if (rows == none) {
        eputs("day04: cannot read " + path + "\n");
        return 1;
    };
    let badat = 0;
    let i = 0;
    while (i < len(rows!)) {
        if (badat == 0 && bad_row(rows![i]) != "") { badat = i + 1 };
        i = i + 1;
    };
    if (badat != 0) {
        eputs("day04: " + path + " line " + tostring(badat) + ": "
              + bad_row(rows![badat - 1]) + "\n");
        return 1;
    };
    let g = parse_rows(rows!);
    // An empty file is a wrong file, not an answer of 0: the statement
    // guarantees a diagram, so refuse rather than print 0.
    if (g.w < MIN_SIDE || g.h < MIN_SIDE) {
        eputs("day04: " + path + " holds no diagram\n");
        return 1;
    };
    if (g.w > MAX_SIDE || g.h > MAX_SIDE) {
        eputs("day04: " + path + " is larger than " + tostring(MAX_SIDE)
              + " on a side\n");
        return 1;
    };
    if (g.rolls == 0) {
        eputs("day04: " + path + " holds no rolls of paper\n");
        return 1;
    };
    let p1 = solve_part1(g);
    let pr = part2_rounds(g.cells, g.w, g.h, D_NONE);
    print("day04: Advent of Code 2025 day 4 -- Printing Department");
    print(f"input: {path}");
    print(f"diagram: {g.w} x {g.h}");
    print(f"rolls: {g.rolls}");
    print(f"part 1 (rolls a forklift can reach): {p1}");
    print(f"part 2 (rolls the cascade takes away): {pr.total}");
    print(f"rolls left standing: {pr.left}");
    print(f"peel rounds: {len(pr.rounds)}");
    print(f"first rounds: {rounds_to_str(pr.rounds, 6)}");
    let tail = len(pr.rounds) - 6;
    if (tail < 0) { tail = 0 };
    print(f"last rounds: {tail_str(pr.rounds, tail)}");
    0
}

// The last few entries of a round list, for the summary line.
def tail_str(rs: [long], from: long) -> str {
    let s = "";
    let i = from;
    while (i < len(rs)) {
        if (i > from) { s += " " };
        s += tostring(rs[i]);
        i = i + 1;
    };
    s
}

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    let f = check_micro();
    f = f + check_example();
    f = f + check_exhaustive(4, 3, true, false, 4095);
    f = f + check_exhaustive(4, 4, false, true, 65535);
    f = f + check_order_independence();
    f = f + check_real("input.txt");
    f = f + check_defects();

    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED (first: {first_failure})");
    f
}

const HELP = "day04 -- Advent of Code 2025 day 4 (Printing Department), in Y

usage:
  ./day04 [FILE]        solve FILE (default input.txt) and print both answers
  ./day04 --check       run the property battery and print every assertion
  ./day04 --heap        report heap_used() around each phase (opt-in, not
                        part of the deterministic run)
  ./day04 --help        this text

part 1: how many rolls have fewer than four rolls in the eight adjacent
        positions (positions off the edge of the diagram are bare floor)
part 2: take away every such roll at once, repeat until none is reachable, and
        count how many rolls were taken away in total
";

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let want_heap = false;
    let have_path = false;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check") {
            want_check = true;
        } else if (a == "--heap") {
            want_heap = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day04: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day04: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day04: more than one input file given (try --help)\n");
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
    if (want_heap) {
        return heap_report(path);
    };
    solve(path)
};
exit(main())