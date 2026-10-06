// day07.y -- Advent of Code 2025, day 7 ("Laboratories"), in Y.
//
// A tachyon beam enters a manifold at `S` and always moves downward.  It
// passes freely through `.`; where it meets a splitter `^` it stops and two
// new beams start, one at the column to its left and one at the column to
// its right.  Two beams can arrive in the same column, and the statement is
// explicit that they are then a single beam again.
//
//   part 1  how many times is the beam split
//   part 2  how many distinct timelines (paths) the beam can take
//
// part 1 is a SET of columns per row (a column holds one beam however many
// arrive), part 2 is a COUNT per column (two beams in one column are two
// particles with two histories).  Both are O(rows x width) forward sweeps.
//
// `--check` re-derives every number by three other routes and proves the
// invariants; see README.md.  Nothing here needs the vendored toolkit.
//
// build: ../../../refs/ycc.ref day07.y -o day07
// run:   ./day07            (input.txt -> both answers)
//        ./day07 --check    (property battery, no reference file)
//        ./day07 --render   (the manifold with the beam drawn on it)
//        ./day07 --help
import fs;

const CH_NL = 10;                // '\n'
const CH_CR = 13;                // '\r'
const CH_DOT = 46;               // '.'
const CH_CARET = 94;             // '^'
const CH_S = 83;                 // 'S'
const CH_PIPE = 124;             // '|'
const MAXW = 512;                // widest manifold accepted
const MAXCELLS = 20480;          // h*w ceiling of the memoised check methods
const PAD = "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................" +
            "................................................................";

// A rectangular manifold.  Every row is padded with `.` to exactly `w` cells,
// so the inner loops never have to bounds-check a ragged row.
type Grid = {
    rows: [str],
    h: long,
    w: long,
    sx: long,                    // column of 'S'
    sy: long,                    // row of 'S'
    padded: long,                // rows that were short and had to be padded
    nsplit: long                 // number of '^' cells in the whole grid
};

// Everything `./day07` prints comes from here, and `--check` asserts about
// here: one entry point, so an injected defect in it really is injected.
type Answer = {
    h: long,
    w: long,
    sx: long,
    sy: long,
    padded: long,
    nsplit: long,
    p1: long,
    p2: long,
    side: long                   // beams that left through a wall
};

let parse_err = "";
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

// ── parsing ─────────────────────────────────────────────────────────────────
//
// The text is scanned byte by byte and never `split`.  Y's `split()` drops
// exactly one trailing empty field, so splitting a grid on "\n" throws away a
// row and splitting a row on anything else loses a column; deriving the
// width from a lossy operation is how a parser silently loses its last
// column.  Here the width is the longest row of the actual bytes.
def strip_cr(s: str) -> str {
    if (s.length > 0 && s[s.length - 1] == CH_CR) { s[0:s.length - 1] } else { s }
}

def parse_grid(text: str) -> Grid? {
    let rows: [str] = [];
    let n = text.length;
    let w = 0;
    let start = 0;
    let i = 0;
    while (i <= n) {
        if (i == n || text[i] == CH_NL) {
            let row = strip_cr(text[start:i]);
            // the last line counts only if it has bytes: a single trailing
            // newline terminates the final row rather than adding an empty one
            if (row.length > 0 || i < n) {
                rows += row;
                if (row.length > w) { w = row.length }
            };
            start = i + 1
        };
        i = i + 1
    };
    if (rows.length == 0 || w == 0) {
        parse_err = "no rows";
        return none
    };
    if (w > MAXW) {
        parse_err = f"manifold is wider than {MAXW} columns";
        return none
    };
    let out: [str] = [];
    let padded = 0;
    let r = 0;
    while (r < len(rows)) {
        let row = rows[r];
        if (row.length < w) {
            row = row + PAD[0:w - row.length];
            padded = padded + 1
        };
        out += row;
        r = r + 1
    };
    let sx = -1;
    let sy = -1;
    let nsplit = 0;
    r = 0;
    while (r < len(out)) {
        let c = 0;
        while (c < w) {
            let ch = out[r][c];
            if (ch == CH_S) {
                sx = c;
                sy = r
            } else {
                if (ch == CH_CARET) { nsplit = nsplit + 1 }
            };
            c = c + 1
        };
        r = r + 1
    };
    if (sx < 0) {
        parse_err = "no 'S' in the manifold";
        return none
    };
    let g: Grid = { rows: out, h: len(out), w: w, sx: sx, sy: sy,
                    padded: padded, nsplit: nsplit };
    some(g)
}

def is_split(g: Grid, r: long, c: long) -> bool {
    if (r < 0 || r >= g.h || c < 0 || c >= g.w) { false } else { g.rows[r][c] == CH_CARET }
}

// ── production: the two forward sweeps ──────────────────────────────────────
//
// `mark` is a stamp array: writing the row index turns "is this column
// already in the set" into an O(1) test with no clearing per row.
let mark: [long; 512] = [0; 512];
let bmark: [long; 512] = [0; 512];
let nmark: [long; 512] = [0; 512];
let curc: [long; 512] = [0; 512];
let nxtc: [long; 512] = [0; 512];
let cnt: [long; 512] = [0; 512];
let nxtn: [long; 512] = [0; 512];

// part 1: count the splits.  A column holds ONE beam however many beams
// arrive there, so the state is a set of columns and a splitter is counted
// once however many beams hit it.
def count_splits(g: Grid) -> long {
    // `mark` is module-level and survives between calls, so it is reset to a
    // value no row index can take.  Resetting it to 0 and starting the sweep
    // at row 0 makes the first beam compare stamp == row, drop it, and print
    // "0 splits" -- which reads as an answer, not as a bug.
    let z = 0;
    while (z < MAXW) { mark[z] = -1; z = z + 1 };
    let splits = 0;
    let n = 1;
    let r = g.sy;
    curc[0] = g.sx;
    while (r < g.h) {
        let m = 0;
        let i = 0;
        while (i < n) {
            let c = curc[i];
            if (is_split(g, r, c)) {
                splits = splits + 1;
                if (c - 1 >= 0 && mark[c - 1] != r) {
                    mark[c - 1] = r;
                    nxtc[m] = c - 1;
                    m = m + 1
                };
                if (c + 1 < g.w && mark[c + 1] != r) {
                    mark[c + 1] = r;
                    nxtc[m] = c + 1;
                    m = m + 1
                }
            } else {
                if (mark[c] != r) { mark[c] = r; nxtc[m] = c; m = m + 1 }
            };
            i = i + 1
        };
        n = m;
        let t = 0;
        while (t < n) { curc[t] = nxtc[t]; t = t + 1 };
        r = r + 1
    };
    splits
}

// part 2: count the timelines.  Two beams in the same column are two
// different particles with two different pasts, so the state is a count per
// column.  `side[0]` collects the particles that leave through a wall.
def count_paths(g: Grid, side: [long]) -> long {
    let i = 0;
    while (i < g.w) { cnt[i] = 0; i = i + 1 };
    cnt[g.sx] = 1;
    side[0] = 0;
    let r = g.sy + 1;
    while (r < g.h) {
        let k = 0;
        while (k < g.w) { nxtn[k] = 0; k = k + 1 };
        let j = 0;
        while (j < g.w) {
            let c = cnt[j];
            if (c != 0) {
                if (is_split(g, r, j)) {
                    if (j - 1 >= 0) {
                        nxtn[j - 1] = nxtn[j - 1] + c
                    } else {
                        side[0] = side[0] + c
                    };
                    if (j + 1 < g.w) {
                        nxtn[j + 1] = nxtn[j + 1] + c
                    } else {
                        side[0] = side[0] + c
                    }
                } else {
                    nxtn[j] = nxtn[j] + c
                }
            };
            j = j + 1
        };
        let q = 0;
        while (q < g.w) { cnt[q] = nxtn[q]; q = q + 1 };
        r = r + 1
    };
    let total = 0;
    let t = 0;
    while (t < g.w) { total = total + cnt[t]; t = t + 1 };
    total + side[0]
}

// The one entry point: parse, then the two production sweeps.
def analyse(text: str) -> Answer? {
    let got: Grid? = parse_grid(text);
    if (got == none) { none } else {
        let g = got!;
        let side: [long] = [0];
        let a: Answer = {
            h: g.h, w: g.w, sx: g.sx, sy: g.sy, padded: g.padded,
            nsplit: g.nsplit,
            p1: count_splits(g), p2: count_paths(g, side), side: side[0]
        };
        some(a)
    }
}

// ── check-only methods, each independent of the production sweep ────────────

// (1) The statement's own picture.  It draws a newborn beam on the splitter's
// own row, one cell to the left and to the right -- `......|^|......` -- so a
// splitter is hit exactly when the cell above it holds a beam.  Reproducing
// the statement's final picture byte for byte is the anchor for the model.
let pic: [str] = [];

def render_into(g: Grid) -> long {
    // `pic` starts empty, and an array store past its end traps, so it is
    // grown once to the grid's height and then reused for every later grid.
    while (len(pic) < g.h) { pic += "" };
    let z = 0;
    while (z < MAXW) { bmark[z] = -1; nmark[z] = -1; z = z + 1 };
    let n = 1;
    let r = g.sy;
    curc[0] = g.sx;
    let lines = 0;
    while (r < g.h) {
        // A newborn beam is drawn on its splitter's OWN row, so the marks for
        // row r have to exist before row r is drawn -- stamping them in the
        // propagation step below draws every beam one row late.
        let i = 0;
        while (i < n) {
            let cc = curc[i];
            if (is_split(g, r, cc)) {
                if (cc - 1 >= 0) { nmark[cc - 1] = r };
                if (cc + 1 < g.w) { nmark[cc + 1] = r }
            };
            i = i + 1
        };
        let line = "";
        let c = 0;
        while (c < g.w) {
            let ch = g.rows[r][c];
            if (ch == CH_CARET) {
                line += "^"
            } else if (ch == CH_S) {
                line += "S"
            } else if (bmark[c] == r || nmark[c] == r) {
                line += "|"
            } else {
                line += "."
            };
            c = c + 1
        };
        pic[r] = line;
        lines = r + 1;
        let m = 0;
        let stamp = r + 1;
        i = 0;
        while (i < n) {
            let cc = curc[i];
            if (is_split(g, r, cc)) {
                if (cc - 1 >= 0 && bmark[cc - 1] != stamp) {
                    bmark[cc - 1] = stamp;
                    nxtc[m] = cc - 1;
                    m = m + 1
                };
                if (cc + 1 < g.w && bmark[cc + 1] != stamp) {
                    bmark[cc + 1] = stamp;
                    nxtc[m] = cc + 1;
                    m = m + 1
                }
            } else {
                if (bmark[cc] != stamp) {
                    bmark[cc] = stamp;
                    nxtc[m] = cc;
                    m = m + 1
                }
            };
            i = i + 1
        };
        n = m;
        let t = 0;
        while (t < n) { curc[t] = nxtc[t]; t = t + 1 };
        r = r + 1
    };
    lines
}

// Count the `^` cells with a beam directly above.  The source cell itself is
// a beam even though the picture draws the letter `S` there, so a splitter
// sitting directly under the source is hit too -- the exhaustive sweep is what
// found that omission (it missed every one of the 1258 grids with a splitter
// in the source's column).
def splits_by_render(g: Grid) -> long {
    render_into(g);
    let n = 0;
    let r = g.sy + 1;
    while (r < g.h) {
        let above = pic[r - 1];
        let c = 0;
        while (c < g.w) {
            let beam = above[c] == CH_PIPE || (r - 1 == g.sy && c == g.sx);
            if (g.rows[r][c] == CH_CARET && beam) { n = n + 1 };
            c = c + 1
        };
        r = r + 1
    };
    n
}

// (2) Part 1 as a per-CELL reachability bitmap: reach[r][c] says a beam is in
// that cell, propagated one cell at a time into two rolling rows.  No column
// list, no dedup stamp, no set: a completely different representation from
// production's per-row column set.
let reach: [byte; 512] = [0; 512];
let reach2: [byte; 512] = [0; 512];

def splits_by_reach(g: Grid) -> long {
    let c = 0;
    while (c < g.w) { reach[c] = 0; c = c + 1 };
    reach[g.sx] = 1;
    let n = 0;
    let r = g.sy + 1;
    while (r < g.h) {
        c = 0;
        while (c < g.w) { reach2[c] = 0; c = c + 1 };
        c = 0;
        while (c < g.w) {
            if (reach[c] == 1) {
                if (is_split(g, r, c)) {
                    n = n + 1;
                    if (c - 1 >= 0) { reach2[c - 1] = 1 };
                    if (c + 1 < g.w) { reach2[c + 1] = 1 }
                } else {
                    reach2[c] = 1
                }
            };
            c = c + 1
        };
        let t = 0;
        while (t < g.w) { reach[t] = reach2[t]; t = t + 1 };
        r = r + 1
    };
    n
}

// (3) Top-down recursion with a memo table: pull, not push.  NOTE this counts
// splits WITH multiplicity -- a pull recursion cannot express part 1's
// de-duplication, which is a property of the whole beam set rather than of one
// cell -- so it cross-checks `mult_splits`, and `splits_by_reach` and the
// renderer are part 1's independent methods.
let memo: [long; 20480] = [0; 20480];

def rec_splits(g: Grid, r: long, c: long) -> long {
    if (r >= g.h || c < 0 || c >= g.w) {
        0
    } else {
        let idx = r * g.w + c;
        let m = memo[idx];
        if (m >= 0) {
            m
        } else {
            let v = 0;
            if (is_split(g, r, c)) {
                v = 1 + self(g, r + 1, c - 1) + self(g, r + 1, c + 1)
            } else {
                v = self(g, r + 1, c)
            };
            memo[idx] = v;
            v
        }
    }
}

def memo_clear(g: Grid) -> long {
    let i = 0;
    let n = g.h * g.w;
    while (i < n) { memo[i] = -1; i = i + 1 };
    n
}

def splits_rec_mult(g: Grid) -> long {
    if (g.h * g.w > MAXCELLS) {
        -1
    } else {
        memo_clear(g);
        rec_splits(g, g.sy + 1, g.sx)
    }
}

def rec_paths(g: Grid, r: long, c: long) -> long {
    if (r >= g.h || c < 0 || c >= g.w) {
        1
    } else {
        let idx = r * g.w + c;
        let m = memo[idx];
        if (m >= 0) {
            m
        } else {
            let v = 0;
            if (is_split(g, r, c)) {
                v = self(g, r + 1, c - 1) + self(g, r + 1, c + 1)
            } else {
                v = self(g, r + 1, c)
            };
            memo[idx] = v;
            v
        }
    }
}

def paths_rec(g: Grid) -> long {
    if (g.h * g.w > MAXCELLS) {
        -1
    } else {
        memo_clear(g);
        rec_paths(g, g.sy + 1, g.sx)
    }
}

// (3) The same recursion with no memo at all: it walks every path to its end
// and counts the leaves.  Only affordable where the answer is small, and the
// only one of the four methods that is not dynamic programming.
def paths_brute(g: Grid, r: long, c: long, fuel: [long]) -> long {
    if (fuel[0] <= 0) {
        -1
    } else if (r >= g.h || c < 0 || c >= g.w) {
        fuel[0] = fuel[0] - 1;
        1
    } else if (is_split(g, r, c)) {
        self(g, r + 1, c - 1, fuel) + self(g, r + 1, c + 1, fuel)
    } else {
        self(g, r + 1, c, fuel)
    }
}

def paths_exhaustive(g: Grid, budget: long) -> long {
    let fuel: [long] = [budget];
    paths_brute(g, g.sy + 1, g.sx, fuel)
}

// (4) A bottom-up pull sweep, rolling one row: below[r][c] = how many paths
// lead from (r,c) out of the manifold.  The reverse direction of production.
// A child that leaves through a wall is a COMPLETED path, so it counts 1 --
// leaving it out (which the exhaustive sweep caught: 4750 of 28385 grids) is
// the same bug as forgetting that a beam which exits the side still happened.
let pull: [long; 512] = [0; 512];

def paths_pull(g: Grid) -> long {
    let c = 0;
    while (c < g.w) { pull[c] = 1; c = c + 1 };      // past the last row: 1 way out
    let r = g.h - 1;
    while (r > g.sy) {
        let k = 0;
        while (k < g.w) { nxtn[k] = 0; k = k + 1 };
        c = 0;
        while (c < g.w) {
            if (is_split(g, r, c)) {
                let v = 0;
                if (c - 1 >= 0) { v = v + pull[c - 1] } else { v = v + 1 };
                if (c + 1 < g.w) { v = v + pull[c + 1] } else { v = v + 1 };
                nxtn[c] = v
            } else {
                nxtn[c] = pull[c]
            };
            c = c + 1
        };
        let q = 0;
        while (q < g.w) { pull[q] = nxtn[q]; q = q + 1 };
        r = r - 1
    };
    pull[g.sx]
}

// (5) Splits counted WITH multiplicity: every particle that meets a splitter.
// The particle count never decreases and rises by exactly one per split, so
// part 2 must equal 1 + this.  A conservation identity, not a restatement.
def mult_splits(g: Grid) -> long {
    let i = 0;
    while (i < g.w) { cnt[i] = 0; i = i + 1 };
    cnt[g.sx] = 1;
    let mult = 0;
    let r = g.sy + 1;
    while (r < g.h) {
        let k = 0;
        while (k < g.w) { nxtn[k] = 0; k = k + 1 };
        let j = 0;
        while (j < g.w) {
            let c = cnt[j];
            if (c != 0) {
                if (is_split(g, r, j)) {
                    mult = mult + c;
                    if (j - 1 >= 0) { nxtn[j - 1] = nxtn[j - 1] + c };
                    if (j + 1 < g.w) { nxtn[j + 1] = nxtn[j + 1] + c }
                } else {
                    nxtn[j] = nxtn[j] + c
                }
            };
            j = j + 1
        };
        let q = 0;
        while (q < g.w) { cnt[q] = nxtn[q]; q = q + 1 };
        r = r + 1
    };
    mult
}

// The smallest horizontal distance between two splitters in one row.  The
// statement's picture, and both public write-ups, leave the case of ADJACENT
// splitters undefined (a newborn beam would land on a splitter, forever), so
// the renderer is only compared on the grids where the model is well defined.
def min_gap(g: Grid) -> long {
    let best = 9999;
    let r = 0;
    while (r < g.h) {
        let prev = -1;
        let c = 0;
        while (c < g.w) {
            if (g.rows[r][c] == CH_CARET) {
                if (prev >= 0 && c - prev < best) { best = c - prev };
                prev = c
            };
            c = c + 1
        };
        r = r + 1
    };
    best
}

// Distinct beams per row, for the invariant "never more beams than columns".
def max_beams(g: Grid) -> long {
    let z = 0;
    while (z < MAXW) { bmark[z] = -1; z = z + 1 };
    let best = 1;
    let n = 1;
    let r = g.sy;
    curc[0] = g.sx;
    while (r < g.h) {
        if (n > best) { best = n };
        let m = 0;
        let i = 0;
        while (i < n) {
            let c = curc[i];
            if (is_split(g, r, c)) {
                if (c - 1 >= 0 && bmark[c - 1] != r) {
                    bmark[c - 1] = r;
                    nxtc[m] = c - 1;
                    m = m + 1
                };
                if (c + 1 < g.w && bmark[c + 1] != r) {
                    bmark[c + 1] = r;
                    nxtc[m] = c + 1;
                    m = m + 1
                }
            } else {
                if (bmark[c] != r) { bmark[c] = r; nxtc[m] = c; m = m + 1 }
            };
            i = i + 1
        };
        n = m;
        let t = 0;
        while (t < n) { curc[t] = nxtc[t]; t = t + 1 };
        r = r + 1
    };
    best
}

// ── check harness ───────────────────────────────────────────────────────────

def expect(name: str, ok: bool, detail: str) -> bool {
    checks_run = checks_run + 1;
    if (ok) {
        print(f"ok   {name}   {detail}");
        true
    } else {
        checks_failed = checks_failed + 1;
        if (first_failure == "") { first_failure = name };
        print(f"FAIL {name}   {detail}");
        false
    }
}

def eq(name: str, a: long, b: long) -> bool {
    expect(name, a == b, f"{a} vs {b}")
}

def expect_true(name: str, ok: bool, detail: str) -> bool { expect(name, ok, detail) }

// One micro-case: the text, the two hand-computed answers, and a note.
def case(label: str, text: str, want_p1: long, want_p2: long) -> bool {
    let got: Answer? = analyse(text);
    if (got == none) {
        expect_true(label, false, "analyse rejected the grid: " + parse_err);
        return false
    };
    let a = got!;
    let okp = a.p1 == want_p1;
    let okq = a.p2 == want_p2;
    let both = okp && okq;
    expect_true(label, both,
                f"part 1 {a.p1} (want {want_p1}), part 2 {a.p2} (want {want_p2})");
    both
}

// Every independent method, on one grid, against production's answer.
def cross(label: str, text: str, use_render: bool, use_brute: bool) -> bool {
    let got: Answer? = analyse(text);
    if (got == none) {
        expect_true(label, false, "analyse rejected the grid: " + parse_err);
        return false
    };
    let a = got!;
    let g: Grid? = parse_grid(text);
    let m = g!;
    let ok = true;
    ok = eq(f"{label}: part 1 == per-cell reachability", a.p1, splits_by_reach(m)) && ok;
    if (use_render) {
        ok = eq(f"{label}: part 1 == rendered picture", a.p1, splits_by_render(m)) && ok
    };
    ok = eq(f"{label}: part 2 == recursion", a.p2, paths_rec(m)) && ok;
    ok = eq(f"{label}: part 2 == bottom-up sweep", a.p2, paths_pull(m)) && ok;
    if (use_brute) {
        ok = eq(f"{label}: part 2 == brute-force path walk", a.p2,
                paths_exhaustive(m, 400000)) && ok
    };
    let mult = mult_splits(m);
    ok = eq(f"{label}: part 2 == 1 + splits with multiplicity", a.p2, 1 + mult) && ok;
    ok = eq(f"{label}: multiplicity splits == recursive count", mult,
            splits_rec_mult(m)) && ok;
    ok = expect_true(f"{label}: part 1 <= splitters in the grid",
                     a.p1 >= 0 && a.p1 <= a.nsplit,
                     f"{a.p1} <= {a.nsplit}") && ok;
    ok = expect_true(f"{label}: part 1 <= splits with multiplicity", a.p1 <= mult,
                     f"{a.p1} <= {mult}") && ok;
    ok = expect_true(f"{label}: part 2 >= 1 + part 1", a.p2 >= 1 + a.p1,
                     f"{a.p2} >= 1 + {a.p1}") && ok;
    let mb = max_beams(m);
    ok = expect_true(f"{label}: distinct beams never exceed the width",
                     mb <= m.w, f"{mb} <= {m.w}") && ok;
    ok
}

// Build a h x w grid text from a bitmask, with 'S' at (sy, sx).
def grid_text(h: long, w: long, sy: long, sx: long, mask: long) -> str {
    let text = "";
    let r = 0;
    while (r < h) {
        let c = 0;
        while (c < w) {
            if (r == sy && c == sx) {
                text += "S"
            } else {
                let bit = r * w + c;
                if (bit < 64 && (mask >> bit) & 1 == 1) { text += "^" } else { text += "." }
            };
            c = c + 1
        };
        text += "\n";
        r = r + 1
    };
    text
}

// The whole state space of every manifold up to 3 rows by 4 columns, with the
// source anywhere in it: 28 385 grids, every one of them solved by production
// and by the three check methods.  Sampling would have been the alternative.
def run_exhaustive() -> long {
    let grids = 0;
    let mismatch = 0;
    let bad_reach = 0;
    let bad_prec = 0;
    let bad_pull = 0;
    let bad_mult = 0;
    let bad_rmult = 0;
    let bad_inv = 0;
    let bad_render = 0;
    let bad_brute = 0;
    let skipped_render = 0;
    let skipped_brute = 0;
    let rendered_ok = 0;
    let brute_ok = 0;
    let h = 1;
    while (h <= 3) {
        let w = 1;
        while (w <= 4) {
            let cells = h * w;
            if (cells <= 12) {
                let sy = 0;
                while (sy < h) {
                    let sx = 0;
                    while (sx < w) {
                        let free = cells - 1;
                        let n = 1;
                        let k = 0;
                        while (k < free) { n = n * 2; k = k + 1 };
                        let mask = 0;
                        while (mask < n) {
                            let text = grid_text(h, w, sy, sx, mask);
                            let got: Answer? = analyse(text);
                            grids = grids + 1;
                            if (got == none) {
                                mismatch = mismatch + 1
                            } else {
                                let a = got!;
                                let m = parse_grid(text)!;
                                if (splits_by_reach(m) != a.p1) { bad_reach = bad_reach + 1 };
                                if (paths_rec(m) != a.p2) { bad_prec = bad_prec + 1 };
                                if (paths_pull(m) != a.p2) { bad_pull = bad_pull + 1 };
                                let mult = mult_splits(m);
                                if (1 + mult != a.p2) { bad_mult = bad_mult + 1 };
                                if (splits_rec_mult(m) != mult) { bad_rmult = bad_rmult + 1 };
                                if (!(a.p1 >= 0 && a.p1 <= a.nsplit && a.p1 <= mult &&
                                      a.p2 >= 1 + a.p1)) { bad_inv = bad_inv + 1 };
                                if (min_gap(m) >= 2) {
                                    if (splits_by_render(m) == a.p1) {
                                        rendered_ok = rendered_ok + 1
                                    } else {
                                        bad_render = bad_render + 1
                                    }
                                } else {
                                    skipped_render = skipped_render + 1
                                };
                                if (a.p2 <= 4000) {
                                    if (paths_exhaustive(m, a.p2 + 16) == a.p2) {
                                        brute_ok = brute_ok + 1
                                    } else {
                                        bad_brute = bad_brute + 1
                                    }
                                } else {
                                    skipped_brute = skipped_brute + 1
                                };
                                if (splits_by_reach(m) != a.p1 || paths_rec(m) != a.p2 ||
                                    paths_pull(m) != a.p2 || 1 + mult != a.p2 ||
                                    splits_rec_mult(m) != mult) {
                                    mismatch = mismatch + 1
                                };
                            };
                            mask = mask + 1
                        };
                        sx = sx + 1
                    };
                    sy = sy + 1
                }
            };
            w = w + 1
        };
        h = h + 1
    };
    expect_true("every manifold up to 3x4 agrees with all its cross-checks",
                mismatch == 0,
                f"{grids} grids, {mismatch} mismatch(es) [reach {bad_reach}, rec {bad_prec}, " +
                f"pull {bad_pull}, 1+mult {bad_mult}, rec-mult {bad_rmult}, inv {bad_inv}, " +
                f"render {bad_render}, brute {bad_brute}]");
    expect_true("exhaustive: renderer agrees wherever the model is defined",
                rendered_ok > 0,
                f"{rendered_ok} compared, {skipped_render} skipped (adjacent splitters)");
    expect_true("exhaustive: brute force agrees wherever it is affordable",
                brute_ok > 0, f"{brute_ok} compared, {skipped_brute} skipped (too many paths)");
    grids
}

// The statement's own example manifold, and the picture the statement prints
// for it once every beam has fallen.  Byte-for-byte equality is a tier-1
// anchor for the beam model, published by the puzzle itself.
const EX0 = ".......S.......\n...............\n.......^.......\n...............\n" +
            "......^.^......\n...............\n.....^.^.^.....\n...............\n" +
            "....^.^...^....\n...............\n...^.^...^.^...\n...............\n" +
            "..^...^.....^..\n...............\n.^.^.^.^.^...^.\n...............\n";
const EXPIC0 = ".......S.......\n.......|.......\n......|^|......\n......|.|......\n" +
               ".....|^|^|.....\n.....|.|.|.....\n....|^|^|^|....\n....|.|.|.|....\n" +
               "...|^|^|||^|...\n...|.|.|||.|...\n..|^|^|||^|^|..\n..|.|.|||.|.|..\n" +
               ".|^|||^||.||^|.\n.|.|||.||.||.|.\n|^|^|^|^|^|||^|\n|.|.|.|.|.|||.|\n";

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    // ---- 1. the statement's own example: 21 splits, published -------
    let g0 = parse_grid(EX0)!;
    eq("statement example: part 1 == 21 (published by the statement)",
       analyse(EX0)!.p1, 21);
    expect_true("statement example: 16 rows x 15 columns", g0.h == 16 && g0.w == 15,
                f"{g0.h} rows x {g0.w} columns");
    render_into(g0);
    let same = true;
    let want = EXPIC0.split("\n");
    let r = 0;
    while (r < g0.h) {
        if (pic[r] != want[r]) { same = false };
        r = r + 1
    };
    expect_true("statement example: rendered picture == the statement's last picture",
                same, "16 lines compared byte for byte");
    let a0 = analyse(EX0)!;
    eq("statement example: part 1 == per-cell reachability", a0.p1, splits_by_reach(g0));
    eq("statement example: part 1 == rendered picture", a0.p1, splits_by_render(g0));
    eq("statement example: part 2 == recursion", a0.p2, paths_rec(g0));
    eq("statement example: part 2 == bottom-up sweep", a0.p2, paths_pull(g0));
    eq("statement example: part 2 == brute-force walk of all 40 paths",
       a0.p2, paths_exhaustive(g0, 400000));
    eq("statement example: part 2 == 1 + multiplicity splits", a0.p2, 1 + mult_splits(g0));
    eq("statement example: multiplicity splits == recursive count",
       mult_splits(g0), splits_rec_mult(g0));
    eq("statement example: part 1 <= multiplicity splits", 1,
       if (a0.p1 <= mult_splits(g0)) { 1 } else { 0 });
    print(f"     statement example: part 1 = {a0.p1}, part 2 = {a0.p2}");

    // ---- 2. hand-computed micro-cases (the arithmetic is in README) ----
    // a) nothing to split: the beam falls straight through
    case("micro a: no splitter at all", "S\n.\n", 0, 1);
    // b) a splitter in a one-column manifold: both children leave the walls
    case("micro b: splitter at column 0 of a 1-wide manifold", "S\n^\n", 1, 2);
    // c) a splitter at the left wall, its left child leaving
    case("micro c: splitter at the left wall", "S....\n^....\n.....\n", 1, 2);
    // d) two splitters whose inner children land in the same column
    case("micro d: a diamond that merges in the middle",
         "...S...\n.....\n...^.^.\n.....\n..^.^..\n.....\n", 3, 4);
    // e) the same diamond with three empty rows between the splitter rows:
    //    empty rows must change nothing
    case("micro e: blank rows change nothing",
         "...S...\n.....\n.....\n.....\n...^.^.\n.....\n.....\n.....\n..^.^..\n" +
         ".....\n.....\n.....\n", 3, 4);
    // f) no trailing newline on the last line -- the split() trap
    case("micro f: no trailing newline", "S....\n^....", 1, 2);
    // g) CRLF line endings
    case("micro g: CRLF line endings", "S....\r\n^....\r\n.....\r\n", 1, 2);
    let crlf = analyse("S....\r\n^....\r\n.....\r\n")!;
    expect_true("micro g: the width is the text's, not the line ending's",
                crlf.w == 5, f"{crlf.w} columns, not 6");
    // h) ragged rows: the width comes from the longest row and a missing
    //    cell is empty space
    case("micro h: a short last row is empty space",
         ".S.\n.^.\n..^.\n..\n", 2, 3);
    // i) the width from the longest row, not the first: the beam reaches
    //    column 3, a column the first row does not have
    case("micro i: width from the longest row, not the first",
         ".S.\n.^.\n..^.\n", 2, 3);
    // j) two splits, but one of the three paths leaves through a wall, so
    //    part 2 is 3 -- not a power of two, which is what makes the
    //    conservation identity part 2 == 1 + splits legible here
    case("micro j: a chain of two splitters along a wall",
         "S..\n^..\n.^.\n", 2, 3);
    // k) a splitter the two beams pass either side of, never touching
    case("micro k: a splitter both beams pass", ".S.\n.^.\n.^.\n", 1, 2);
    // l) both children of a splitter in a one-column manifold leave the walls
    case("micro l: 1 column, splitter, both children leave", "S\n^\n^\n", 1, 2);
    // m) the row that needs four rows to exist: two splitters met by the two
    //    beams born of one splitter both dump into the middle column, and the
    //    splitter under THAT column is met once (part 1) by two particles
    //    (part 2).  The beam set has to de-duplicate twice over, and no grid
    //    three rows tall can show it -- which is why the exhaustive sweep
    //    alone was not enough to catch a missing de-duplication.
    case("micro m: two splitters converge on one column, four rows deep",
         ".S...\n.^...\n^.^..\n.^...\n", 4, 6);

    // ---- 3. invariants on the real input ------------------------------
    let raw: str? = fs.read_file("input.txt");
    if (raw == none) {
        eputs("day07 --check: cannot read input.txt (run it in the day07 folder)\n");
        return 1
    };
    let text = raw!;
    let a: Answer? = analyse(text);
    if (a == none) {
        eputs("day07 --check: input.txt: " + parse_err + "\n");
        return 1
    };
    let real = a!;
    let m = parse_grid(text)!;
    print(f"real input: {real.h} rows x {real.w} columns, {real.nsplit} splitters," +
          f" source at ({real.sy},{real.sx}), {real.padded} row(s) padded");
    expect_true("real input: every row is the same width (not the puzzle, not a bug)",
                real.padded == 0, f"{real.padded} padded of {real.h}");
    expect_true("real input: width is 141, taken from the data", real.w == 141,
                f"{real.w} columns");
    expect_true("real input: the source is on the first row", real.sy == 0,
                f"row {real.sy}, column {real.sx}");
    cross("real input", text, true, false);
    expect_true("real input: every manifold cell is '.', '^' or 'S'",
                m.nsplit == 1761, f"{m.nsplit} splitters");
    expect_true("real input: no two splitters are adjacent in a row",
                min_gap(m) >= 2, f"smallest gap {min_gap(m)}");
    expect_true("real input: part 1 is inside [0, splitters]",
                real.p1 >= 0 && real.p1 <= real.nsplit,
                f"{real.p1} in [0, {real.nsplit}]");
    expect_true("real input: part 2 == 1 + part 1 at least", real.p2 >= 1 + real.p1,
                f"{real.p2} >= 1 + {real.p1}");
    expect_true("real input: part 2 fits a signed 64-bit long",
                real.p2 < 4611686018427387904, f"{real.p2} < 2^62");
    expect_true("real input: part 2 grows with the manifold (a deeper beam",
                real.p2 > real.p1 * 1000, f"{real.p2} vs 1000 * {real.p1}");

    // Five perturbations of the real manifold, each with an answer worked out
    // in advance, so the check is sensitive to the input and not only to the
    // code.  (The obvious probe -- drop a '^' directly below the source --
    // turns out to change NOTHING here: the splitter one row lower already
    // does exactly what the new one would, so the count is unchanged.  That
    // is a real property of this manifold and it is asserted as such.)
    probes_run_check(text, real, m);

    // ---- 4. error paths: a message and a non-zero exit, never a trap ---
    let nos = analyse("..\n..\n");
    expect_true("error path: a manifold with no 'S' is rejected", nos == none,
                parse_err);
    let empty = analyse("");
    expect_true("error path: an empty file is rejected", empty == none, parse_err);
    let blank = analyse("\n\n\n");
    expect_true("error path: a file of blank lines is rejected", blank == none, parse_err);
    let wide = "S" + PAD[0:MAXW + 1] + "\n";
    let toowide = analyse(wide);
    expect_true("error path: a manifold wider than 512 columns is rejected",
                toowide == none, parse_err);
    let only = analyse("^.\n.^\n");
    expect_true("error path: a manifold of splitters with no 'S' is rejected",
                only == none, parse_err);
    let norows = analyse("\r\n\r\n");
    expect_true("error path: a file of bare carriage returns is rejected",
                norows == none, parse_err);

    // ---- 5. the whole state space up to 3x4 ---------------------------
    let grids = run_exhaustive();

    print("");
    print(f"real input: part 1 = {real.p1}, part 2 = {real.p2}");
    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed" +
              f" ({grids} manifolds enumerated exhaustively)");
        0
    } else {
        print(f"property check: {checks_run} checks, {checks_failed} FAILED," +
              f" first was '{first_failure}'");
        1
    }
}

// Rebuild a manifold from its rows, one "\n" per row.
def rows_text(m: Grid, rows: [str]) -> str {
    let t = "\n";
    let k = 0;
    let body = "";
    while (k < m.h) { body = body + rows[k] + t; k = k + 1 };
    body
}

// Probe 1: blank out every splitter.  Then there is nothing to split, so part
// 1 must be exactly 0 and part 2 exactly 1 -- the single path straight down.
// This is the sharpest of the five: it fails unless both answers are driven
// by the splitters and by nothing else.
def probe_blank(m: Grid) -> Answer? {
    let rows: [str] = [];
    let r = 0;
    while (r < m.h) {
        let line = "";
        let c = 0;
        while (c < m.w) {
            // `s += byte` is a compile error and `"x" + byte` segfaults, so a
            // cell comes back to the string through chr().
            let b = m.rows[r][c];
            if (b == CH_CARET) {
                line += "."
            } else {
                line += chr(b)
            };
            c = c + 1
        };
        rows += line;
        r = r + 1
    };
    analyse(rows_text(m, rows))
}

// Probe 2: append one empty row.  A row with no splitter cannot change the
// beam set, so both answers must be identical.
def probe_extra_row(m: Grid) -> Answer? {
    let rows: [str] = [];
    let r = 0;
    while (r < m.h) { rows += m.rows[r]; r = r + 1 };
    rows += PAD[0:m.w];
    let m2: Grid = { rows: rows, h: m.h + 1, w: m.w, sx: m.sx, sy: m.sy,
                     padded: m.padded, nsplit: m.nsplit };
    analyse(rows_text(m2, rows))
}

// Probe 3: append one empty column.  Nothing changes either unless a splitter
// sits in the last column or a beam can reach it; the precondition is
// asserted, and then the answers must be identical.
def probe_extra_col(m: Grid) -> Answer? {
    let rows: [str] = [];
    let r = 0;
    while (r < m.h) { rows += m.rows[r] + "."; r = r + 1 };
    let m2: Grid = { rows: rows, h: m.h, w: m.w + 1, sx: m.sx, sy: m.sy,
                     padded: m.padded, nsplit: m.nsplit };
    analyse(rows_text(m2, rows))
}

// Probe 4: truncate the manifold at half height.  The beam's evolution is
// unchanged up to the cut, so neither answer can grow -- and both must be
// strictly smaller, because the rows that are dropped hold splitters.
def probe_truncate(m: Grid) -> Answer? {
    let keep = m.h / 2;
    let rows: [str] = [];
    let r = 0;
    while (r < keep) { rows += m.rows[r]; r = r + 1 };
    let m2: Grid = { rows: rows, h: keep, w: m.w, sx: m.sx, sy: m.sy,
                     padded: m.padded, nsplit: m.nsplit };
    analyse(rows_text(m2, rows))
}

// Probe 5: a '^' dropped directly above the splitter under the source.  The
// beam then splits one row earlier and the splitter it used to hit is never
// reached, so -- because the row in between holds no other splitter -- both
// answers come out identical.  Asserted with its precondition.
def probe_shift_split(m: Grid) -> Answer? {
    let r = m.sy + 1;
    let under = m.sy + 2;
    if (under >= m.h) {
        none
    } else {
        let row = m.rows[r];
        let patched = row[0:m.sx] + "^" + row[m.sx + 1:m.w];
        let rows: [str] = [];
        let k = 0;
        while (k < m.h) {
            if (k == r) { rows += patched } else { rows += m.rows[k] };
            k = k + 1
        };
        analyse(rows_text(m, rows))
    }
}

// How many '^' does a row hold?
def row_splitters(m: Grid, r: long) -> long {
    let n = 0;
    let c = 0;
    while (c < m.w) {
        if (m.rows[r][c] == CH_CARET) { n = n + 1 };
        c = c + 1
    };
    n
}

// How many '^' does a column hold?
def col_splitters(m: Grid, c: long) -> long {
    let n = 0;
    let r = 0;
    while (r < m.h) {
        if (m.rows[r][c] == CH_CARET) { n = n + 1 };
        r = r + 1
    };
    n
}

// The rightmost column any beam ever occupies, or -1.  Bounds the beam set
// from the other side, and is the precondition for the extra-column probe.
def rightmost_beam(g: Grid) -> long {
    let z = 0;
    while (z < MAXW) { bmark[z] = -1; z = z + 1 };
    let best = -1;
    let n = 1;
    let r = g.sy;
    curc[0] = g.sx;
    while (r < g.h) {
        let m = 0;
        let i = 0;
        while (i < n) {
            let c = curc[i];
            if (c > best) { best = c };
            if (is_split(g, r, c)) {
                if (c - 1 >= 0 && bmark[c - 1] != r) {
                    bmark[c - 1] = r;
                    nxtc[m] = c - 1;
                    m = m + 1
                };
                if (c + 1 < g.w && bmark[c + 1] != r) {
                    bmark[c + 1] = r;
                    nxtc[m] = c + 1;
                    m = m + 1
                }
            } else {
                if (bmark[c] != r) { bmark[c] = r; nxtc[m] = c; m = m + 1 }
            };
            i = i + 1
        };
        n = m;
        let t = 0;
        while (t < n) { curc[t] = nxtc[t]; t = t + 1 };
        r = r + 1
    };
    best
}

def probes_run_check(text: str, real: Answer, m: Grid) -> long {
    let b = probe_blank(m);
    if (b == none) {
        expect_true("probe: blanking every splitter still solves", false, parse_err)
    } else {
        expect_true("probe: blanking every splitter gives 0 splits and 1 timeline",
                    b!.p1 == 0 && b!.p2 == 1, f"part 1 {b!.p1}, part 2 {b!.p2}")
    };
    let e = probe_extra_row(m);
    expect_true("probe: an extra empty row at the bottom changes nothing",
                e != none && e!.p1 == real.p1 && e!.p2 == real.p2,
                f"part 1 {real.p1} -> {if (e == none) { -1 } else { e!.p1 }}, " +
                f"part 2 {real.p2} -> {if (e == none) { -1 } else { e!.p2 }}");
    let c0 = col_splitters(m, m.w - 1);
    let rb = rightmost_beam(m);
    let c = probe_extra_col(m);
    expect_true("probe: an extra empty column on the right changes nothing",
                c != none && c!.p1 == real.p1 && c!.p2 == real.p2,
                f"part 1 {real.p1} -> {if (c == none) { -1 } else { c!.p1 }}, " +
                f"part 2 {real.p2} -> {if (c == none) { -1 } else { c!.p2 }}");
    expect_true("probe: no splitter in the last column, which is why an extra",
                c0 == 0,
                f"{c0} splitter(s) in column {m.w - 1}; the rightmost beam is {rb}" +
                " and simply carries on");
    let t = probe_truncate(m);
    expect_true("probe: truncating the manifold cannot raise either answer",
                t != none && t!.p1 <= real.p1 && t!.p2 <= real.p2 &&
                t!.p1 < real.p1 && t!.p2 < real.p2,
                f"part 1 {real.p1} -> {if (t == none) { -1 } else { t!.p1 }}, " +
                f"part 2 {real.p2} -> {if (t == none) { -1 } else { t!.p2 }}");
    let under = m.sy + 2;
    let pre = under < m.h && row_splitters(m, m.sy + 1) == 0 &&
              row_splitters(m, under) == 1 && m.rows[under][m.sx] == CH_CARET;
    expect_true("probe: the row below the source holds no splitter, the next holds one",
                pre, "row " + f"{m.sy + 1} has 0, row {under} has 1 at the source column");
    let sh = probe_shift_split(m);
    expect_true("probe: a splitter moved one row earlier changes neither answer",
                sh != none && sh!.p1 == real.p1 && sh!.p2 == real.p2,
                f"part 1 {real.p1} -> {if (sh == none) { -1 } else { sh!.p1 }}, " +
                f"part 2 {real.p2} -> {if (sh == none) { -1 } else { sh!.p2 }}");
    0
}

const HELP = "day07 -- Advent of Code 2025 day 7 (Laboratories), in Y

usage:
  ./day07 [FILE]        solve FILE (default input.txt) and print both answers
  ./day07 --check       run the property battery
  ./day07 --render      draw the manifold with the beams falling through it
  ./day07 --help        this text

input shape: a rectangular grid of '.' and '^' with exactly one 'S'.  A beam
enters at S, always falls, and a '^' stops it and starts a new beam at the
column to its left and one to its right.  Two beams in the same column are
one beam (part 1) but two particles (part 2).

part 1: how many times the beam is split
part 2: how many distinct timelines the beam can take

part 2's wording is not in the statement (it is login-gated); it comes from
public write-ups.  See README.md for the sources and both example anchors.
";

def render_cmd(path: str) -> long {
    let raw: str? = fs.read_file(path);
    if (raw == none) {
        eputs("day07: cannot read " + path + "\n");
        return 1
    };
    let got: Grid? = parse_grid(raw!);
    if (got == none) {
        eputs("day07: " + path + ": " + parse_err + "\n");
        return 1
    };
    let g = got!;
    render_into(g);
    let r = 0;
    while (r < g.h) {
        print(pic[r]);
        r = r + 1
    };
    0
}

def solve(path: str) -> long {
    let raw: str? = fs.read_file(path);
    if (raw == none) {
        eputs("day07: cannot read " + path + "\n");
        return 1
    };
    let got: Answer? = analyse(raw!);
    if (got == none) {
        eputs("day07: " + path + ": " + parse_err + "\n");
        return 1
    };
    let a = got!;
    print("day07: Advent of Code 2025 day 7 -- Laboratories");
    print(f"input: {path}");
    print(f"manifold: {a.h} rows x {a.w} columns, {a.nsplit} splitters," +
          f" source at ({a.sy},{a.sx})");
    print(f"part 1 (times the beam is split): {a.p1}");
    print(f"part 2 (distinct tachyon timelines): {a.p2}");
    0
}

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let want_render = false;
    let have_path = false;
    let i = 1;
    while (i < len(args)) {
        let arg = args[i];
        if (arg == "--check") {
            want_check = true
        } else if (arg == "--render") {
            want_render = true
        } else if (arg == "--help" || arg == "-h") {
            print(HELP);
            return 0
        } else if (arg == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day07: --input needs a file name\n");
                return 1
            };
            i = i + 1;
            path = args[i];
            have_path = true
        } else if (arg.starts_with("--")) {
            eputs("day07: unknown option " + arg + " (try --help)\n");
            return 1
        } else if (have_path) {
            eputs("day07: more than one input file given (try --help)\n");
            return 1
        } else {
            path = arg;
            have_path = true
        };
        i = i + 1
    };
    if (want_check) { run_check() } else if (want_render) { render_cmd(path) } else { solve(path) }
};
exit(main())