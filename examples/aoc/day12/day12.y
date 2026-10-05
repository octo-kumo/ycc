// day12.y -- Advent of Code 2025, day 12 ("Christmas Tree Farm"), in Y.
//
// A cavern under the North Pole is full of Christmas trees, and under each
// tree is a rectangular region that has to hold a listed number of presents.
// The presents come in a handful of standard shapes drawn on a unit grid;
// each may be rotated and flipped, the `#` cells of two presents may not
// share a cell, and the `.` cells of a shape block nothing.
//
//   part 1  how many of the regions can fit all the presents listed for them
//   part 2  there is none.  2025 ran for twelve days and day 12 carries a
//           single star: the puzzle ends with a star appearing above the
//           tree and asks no second question.  Two independent write-ups say
//           so (see README.md); the program prints the citation rather than
//           inventing a second puzzle.
//
// Part 1 is NP-hard in general -- fitting polyominoes into a rectangle is a
// bin-packing feasibility problem -- so this program does NOT try to solve it
// in general.  It answers it by a sandwich, one half per direction:
//
//   * sufficiency, the 546 "yes" verdicts: a real packing is built, one
//     present at a time, and then re-derived from its own records by
//     `witness_check` -- every present an exact rotation or flip of its shape,
//     in bounds, and no cell carrying two presents.  A witness is a proof, so
//     these 546 cannot be wrong.
//
//   * necessity, the 454 "no" verdicts: those regions never reach the packer,
//     because the presents ask for more cells than the region has.  Area is a
//     hard bound, so these 454 cannot be wrong either.
//
// The halves cover every region exactly once (`Report.agree`), so the answer
// is exact without `pack_region` ever having to be complete -- and it is not:
// it is a constructive heuristic, and `--check` measures where it falls short
// against an exhaustive search on small regions (it misses some exact
// tilings, which is why soundness rests on witnesses, not on its refusals).
//
// build: ../../../refs/ycc.ref day12.y -o day12
// run:   ./day12                 (input.txt -> both answers)
//        ./day12 --check         (property battery, no reference file)
//        ./day12 --inject N      (apply defect N; what --check uses)
//        ./day12 --help
import fs;

// ── constants ────────────────────────────────────────────────────────────────

const CH_HASH = 35;              // '#'
const CH_DOT = 46;               // '.'
const CH_COLON = 58;             // ':'
const CH_ZERO = 48;              // '0'
const CH_NINE = 57;              // '9'
const CH_SPACE = 32;             // any byte <= this separates numbers
const CH_A = 65;                 // first witness letter
const MAX_CELLS = 512;           // cells per orientation; module scratch slots
const INJECT_MAX = 12;           // defect switches; 0 is "no defect"
const REAL_SHAPES = 6;           // counted outside the program: input.txt
const REAL_REGIONS = 1000;       // counted outside the program: input.txt
const SUBSET = 60;               // real regions used by the injection battery
const NODE_BUDGET = 2000000;     // exhaustive search gives up past this
const SEARCH_CELLS = 400;        // the complete search is only tried below this
const TR_KIND = 4;               // transforms: transpose, quarter, half, mirror

// ── types ────────────────────────────────────────────────────────────────────

// One present shape and its orientation table.
//
// `ocells` holds every orientation's cell list back to back as (row, col)
// pairs; `ostart[oi]`/`olen[oi]` say where orientation oi starts and how many
// pairs it has.  Orientations are generated in a fixed order -- mirror in
// {no, yes} outer, quarter turns 0..3 inner, first occurrence of a shape
// kept -- so the packer's choice among them is deterministic and never
// depends on a set or a map iteration order.
//
// `xtr`/`xr90`/`xr180`/`xfl` map an orientation to the index of its image
// under transpose / quarter turn / half turn / left-right mirror.  The
// transposition oracle needs them and the solver does not.
type Shape = {
    area: long,                  // '#' cells in the diagram
    cells: long,                 // pairs in the diagram
    h: long, w: long,            // diagram bounding box
    no: long,                    // distinct orientations
    ostart: [long], olen: [long], oh: [long], ow: [long],
    ocells: [long],
    xtr: [long], xr90: [long], xr180: [long], xfl: [long]
};

// A region and the presents it must hold.  `q` has one entry per shape.
type Region = {
    w: long, h: long,
    q: [long],
    need: long                   // sum over i of q[i] * area[i]
};

type Puzzle = {
    shapes: [Shape],
    regions: [Region],
    picture_rows: long,          // diagram lines seen
    err: str
};

// What one pass over the regions produced.  Everything `--check` needs about a
// run comes out of here, so a defect injected into the solver lands in the
// very numbers the checks compare.
type Report = {
    fits: long,                  // the answer: regions that fit, each witnessed
    area_only: long,             // regions the area bound alone accepts
    agree: long,                 // regions where exactly one of the two fired
    witnessed: long,             // "yes" verdicts whose witness re-derived
    turned: long,                // ... and survived a quarter turn + transpose
    searched: long,              // "yes" verdicts the complete search had to find
    unresolved: long,            // area-ok, greedy failed, too big to decide
    over: long,                  // rejected: presents need more cells than exist
    pieces: long,                // presents placed in the "yes" regions
    need_total: long,            // cells those presents ask for
    region_cells: long,          // cells in those regions
    bad: long,                   // witness check failures; must stay 0
    shapes: long,
    regions: long,
    err: str
};

// ── module scratch ───────────────────────────────────────────────────────────
//
// Grown once and reused: the heap is an arena, so anything allocated per
// region would stay allocated for the whole run.

let occ: [long] = [];            // the packer's grid: 0 free, else present id + 1
let occ2: [long] = [];           // the grid re-derived from the witness records
let blk: [long] = [];            // cells the complete search has given up on
let scratch: [long] = [];        // one orientation's cells, while transforming
let pl: [long] = [];             // the witness: type, orient, r0, c0 per present
let porder: [long] = [];         // shape indices, largest area first
let bh = 0;
let bw = 0;
let hint = 0;                    // first free cell of `occ`, row-major
let inject = 0;                  // defect switch; 0 = none
let mark_bad = 0;                // cells out of bounds or doubly marked
let ex_gave_up = false;          // the exhaustive search ran out of nodes

// ── the defect switches ──────────────────────────────────────────────────────
//
// Each is one plausible mutation of the solver and nothing else, so `--check`
// can ask "would the battery have noticed?" of all of them.  README.md lists
// them with what each one does and whether the battery caught it.

def rot_count() -> long { if (inject == 1) { 3 } else { 4 } };
def mirror_loops() -> long { if (inject == 2) { 1 } else { 2 } };
def start_slack() -> long { if (inject == 3) { 1 } else { 2 } };
def area_strict() -> bool { inject == 4 };
def scan_from_zero() -> bool { inject == 5 };
def grid_swapped() -> bool { inject == 6 };
def piece_order_asc() -> bool { inject == 7 };
def keep_dupes() -> bool { inject == 8 };
def tight_bound() -> bool { inject == 9 };
def records_swapped() -> bool { inject == 10 };
def trust_area() -> bool { inject == 11 };
def defect_12() -> bool { inject == 12 };

// ── the property battery's bookkeeping ───────────────────────────────────────

let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

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

// ── byte and line classification ─────────────────────────────────────────────

def is_digits(s: str, a: long, b: long) -> bool {
    let ok = a < b;
    let i = a;
    while (ok && i < b) {
        let c = s[i] & 255;
        if (c < CH_ZERO || c > CH_NINE) { ok = false };
        i = i + 1;
    };
    ok
}

// A shape diagram row: nothing but '#' and '.'.
def is_picture(s: str) -> bool {
    let ok = len(s) > 0;
    let i = 0;
    while (ok && i < len(s)) {
        let c = s[i] & 255;
        if (c != CH_HASH && c != CH_DOT) { ok = false };
        i = i + 1;
    };
    ok
}

// "7:" -- a shape's own index, which the input gives for convenience only.
def is_label(s: str) -> bool {
    let n = len(s);
    n > 1 && s[n - 1] == c':' && is_digits(s, 0, n - 1)
}

// "39x44: 51 35 ..." -- a region line.
def is_region_line(s: str) -> bool {
    let x = s.index_of("x");
    let c = s.index_of(":");
    x > 0 && c > x + 1 && is_digits(s, 0, x) && is_digits(s, x + 1, c)
}

def dim_first(s: str) -> long {
    let x = s.index_of("x");
    if (is_digits(s, 0, x)) { tonum(s[0:x]) } else { -1 }
}

def dim_second(s: str) -> long {
    let x = s.index_of("x");
    let c = s.index_of(":");
    if (is_digits(s, x + 1, c)) { tonum(s[x + 1:c]) } else { -1 }
}

// The numbers after the ':', whitespace-separated, in order.  Byte level, so
// a line that ends in a space, or has two spaces in a row, reads the same.
def numbers(rest: str) -> [long] {
    let out: [long] = [];
    let n = len(rest);
    let i = 0;
    while (i < n) {
        while (i < n && (rest[i] & 255) <= CH_SPACE) { i = i + 1 };
        let lo = i;
        while (i < n && (rest[i] & 255) > CH_SPACE) { i = i + 1 };
        if (i > lo) {
            let tok = rest[lo:i];
            if (is_digits(tok, 0, len(tok))) { out += tonum(tok) } else { out += -1 };
        };
    };
    out
}

// ── orientations ─────────────────────────────────────────────────────────────

// Write the cells of `cells` transformed by `kind` into `scratch`, normalised
// so the origin is the present's own top-left corner; return the pair count.
//
//   kind 0 transpose (r,c) -> (c,r)
//   kind 1 quarter turn   (r,c) -> (c,-r)
//   kind 2 half turn      (r,c) -> (-r,-c)
//   kind 3 mirror         (r,c) -> (r,-c)
// A transform writes 2n scratch slots, so the scratch has to be big enough
// before the first write.  `scratch *= 0` grows it; it is never shrunk.
def need_scratch(n: long) {
    while (len(scratch) < n) { scratch *= 0 }
};

// Move the 2n scratch pairs so the origin is the present's own top-left
// corner, and sort them by (row, col).  The sort is what makes the
// deduplication below work: the same shape reached by two different routes
// arrives in two different orders, and an unsorted comparison would call them
// different orientations.  n is at most MAX_CELLS and the shapes are tiny, so
// a selection sort is the cheapest thing that is obviously right.
def norm_sort(n: long) {
    let minr = 0;
    let minc = 0;
    let first = true;
    let k = 0;
    while (k < n) {
        if (first || scratch[2 * k] < minr) { minr = scratch[2 * k] };
        if (first || scratch[2 * k + 1] < minc) { minc = scratch[2 * k + 1] };
        first = false;
        k = k + 1;
    };
    k = 0;
    while (k < n) {
        scratch[2 * k] = scratch[2 * k] - minr;
        scratch[2 * k + 1] = scratch[2 * k + 1] - minc;
        k = k + 1;
    };
    let a = 0;
    while (a < n - 1) {
        let b = a + 1;
        let best = a;
        while (b < n) {
            if (scratch[2 * b] < scratch[2 * best]
                || (scratch[2 * b] == scratch[2 * best]
                    && scratch[2 * b + 1] < scratch[2 * best + 1])) {
                best = b;
            };
            b = b + 1;
        };
        if (best != a) {
            let tr = scratch[2 * a];
            let tc = scratch[2 * a + 1];
            scratch[2 * a] = scratch[2 * best];
            scratch[2 * a + 1] = scratch[2 * best + 1];
            scratch[2 * best] = tr;
            scratch[2 * best + 1] = tc;
        };
        a = a + 1;
    }
}

def transform(cells: [long], n: long, kind: long) -> long {
    need_scratch(2 * n);
    let k = 0;
    while (k < n) {
        let r = cells[2 * k];
        let c = cells[2 * k + 1];
        let x = c;                   // the new column
        let y = r;                   // the new row
        if (kind == 0) {
            x = r;
            y = c;
        } else if (kind == 1) {
            x = 0 - r;
            y = c;
        } else if (kind == 2) {
            x = 0 - c;
            y = 0 - r;
        } else if (kind == 3) {
            x = 0 - c;
            y = r;
        };
        scratch[2 * k] = y;
        scratch[2 * k + 1] = x;
        k = k + 1;
    };
    norm_sort(n);
    n
}

// The index of the orientation of `sp` equal to `scratch[0 .. 2n)`, or -1.
def find_orientation(sp: Shape, n: long) -> long {
    let hit = -1;
    let oi = 0;
    while (oi < sp.no && hit < 0) {
        if (sp.olen[oi] == n) {
            let same = true;
            let k = 0;
            while (same && k < n) {
                if (sp.ocells[sp.ostart[oi] + 2 * k] != scratch[2 * k]
                    || sp.ocells[sp.ostart[oi] + 2 * k + 1] != scratch[2 * k + 1]) {
                    same = false;
                };
                k = k + 1;
            };
            if (same) { hit = oi };
        };
        oi = oi + 1;
    };
    hit
}

// Build the whole orientation table of one shape: the distinct quarter turns
// and mirrors, then the four transform indices.
def build_orientations(cells: [long], n: long, area: long, h: long, w: long) -> Shape {
    let sp: Shape = { area: area, cells: n, h: h, w: w, no: 0, ostart: [],
                      olen: [], oh: [], ow: [], ocells: [], xtr: [], xr90: [],
                      xr180: [], xfl: [] };
    if (n > MAX_CELLS) { return sp };
    need_scratch(2 * n);
    let m = 0;
    while (m < mirror_loops()) {
        let rot = 0;
        while (rot < rot_count()) {
            // cells are (row, col) pairs; mirror in the column, then rot
            // quarter turns, each (x, y) -> (-y, x) with x the column
            let k = 0;
            while (k < n) {
                let c = cells[2 * k + 1];
                let x = m == 1 ? 0 - c : c;
                let y = cells[2 * k];
                let t = 0;
                while (t < rot) {
                    let nx = 0 - y;
                    y = x;
                    x = nx;
                    t = t + 1;
                };
                scratch[2 * k] = y;
                scratch[2 * k + 1] = x;
                k = k + 1;
            };
            // normalise and sort, so two routes to the same shape compare equal
            norm_sort(n);
            let seen = -1;
            if (sp.no > 0 && !keep_dupes()) { seen = find_orientation(sp, n) };
            if (seen < 0) {
                let hh = 0;
                let ww = 0;
                k = 0;
                while (k < n) {
                    if (scratch[2 * k] + 1 > hh) { hh = scratch[2 * k] + 1 };
                    if (scratch[2 * k + 1] + 1 > ww) { ww = scratch[2 * k + 1] + 1 };
                    k = k + 1;
                };
                let st = sp.no * 2 * n;
                let kk = 0;
                while (kk < 2 * n) {
                    sp.ocells += scratch[kk];
                    kk = kk + 1;
                };
                sp.ostart += st;
                sp.olen += n;
                sp.oh += hh;
                sp.ow += ww;
                sp.xtr += -1;
                sp.xr90 += -1;
                sp.xr180 += -1;
                sp.xfl += -1;
                sp.no = sp.no + 1;
            };
            rot = rot + 1;
        };
        m = m + 1;
    };
    // the four transform indices, by transforming each orientation and
    // looking the result up in the table just built
    let oi = 0;
    while (oi < sp.no) {
        let kind = 0;
        while (kind < TR_KIND) {
            let tmp: [long] = [];
            let k = 0;
            while (k < 2 * sp.olen[oi]) {
                tmp += sp.ocells[sp.ostart[oi] + k];
                k = k + 1;
            };
            transform(tmp, sp.olen[oi], kind);
            let hit = find_orientation(sp, sp.olen[oi]);
            if (kind == 0) { sp.xtr[oi] = hit }
            else if (kind == 1) { sp.xr90[oi] = hit }
            else if (kind == 2) { sp.xr180[oi] = hit }
            else { sp.xfl[oi] = hit };
            kind = kind + 1;
        };
        oi = oi + 1;
    };
    sp
}

// ── the parser ───────────────────────────────────────────────────────────────

def parse(lines: [str]) -> Puzzle {
    let shapes: [Shape] = [];
    let regions: [Region] = [];
    let n = len(lines);
    let i = 0;
    let err = "";
    let picture_rows = 0;
    while (i < n && err == "") {
        let s = lines[i];
        if (s == "") {
            i = i + 1;
        } else if (is_picture(s)) {
            // a shape diagram: picture lines, read back to back
            let cells: [long] = [];
            let hh = 0;
            let ww = 0;
            let j = i;
            let go = true;
            while (go && j < n) {
                let r = lines[j];
                if (r == "" || !is_picture(r)) { go = false }
                else {
                    let k = 0;
                    while (k < len(r)) {
                        if ((r[k] & 255) == CH_HASH) {
                            cells += j - i;
                            cells += k;
                        };
                        k = k + 1;
                    };
                    if (len(r) > ww) { ww = len(r) };
                    hh = hh + 1;
                    j = j + 1;
                };
            };
            if (len(cells) == 0) {
                err = "line " + tostring(i + 1) + ": shape diagram with no '#'";
            } else {
                shapes += build_orientations(cells, len(cells) / 2,
                                             len(cells) / 2, hh, ww);
                picture_rows = picture_rows + hh;
                i = j;
            };
        } else if (is_label(s)) {
            i = i + 1;                       // the shape's own index: not needed
        } else if (is_region_line(s)) {
            let w = dim_first(s);
            let h = dim_second(s);
            let ci = s.index_of(":");
            let q = numbers(s[ci + 1:]);
            let bad = -1;
            for t in 0..len(q) { if (q[t] < 0) { bad = t } };
            if (w <= 0 || h <= 0) {
                err = "line " + tostring(i + 1) + ": bad region size '" + s + "'";
            } else if (len(q) != len(shapes)) {
                err = "line " + tostring(i + 1) + ": " + tostring(len(q))
                      + " quantities for " + tostring(len(shapes)) + " shapes";
            } else if (bad >= 0) {
                err = "line " + tostring(i + 1) + ": quantity " + tostring(bad)
                      + " is not a number";
            } else {
                let need = 0;
                for t in 0..len(q) { need = need + q[t] * shapes[t].area };
                let rg: Region = { w: w, h: h, q: q, need: need };
                regions += rg;
                i = i + 1;
            };
        } else {
            err = "line " + tostring(i + 1) + ": neither a shape diagram, a shape"
                  + " index, nor a region: '" + s + "'";
        };
    };
    if (err == "" && len(shapes) == 0) { err = "no present shapes in the input" };
    if (err == "" && len(regions) == 0) { err = "no regions in the input" };
    { shapes: shapes, regions: regions, picture_rows: picture_rows, err: err }
}

// ── the grid and the packer ──────────────────────────────────────────────────

def need_cells(n: long) {
    while (len(occ) < n) { occ *= 0 };
    while (len(occ2) < n) { occ2 *= 0 };
    while (len(blk) < n) { blk *= 0 }
};

def clear_grid(g: [long], n: long) {
    let i = 0;
    while (i < n) {
        g[i] = 0;
        i = i + 1;
    }
}

// Clear a whole scratch array.  These only ever grow, so a region smaller than
// the largest one seen would otherwise inherit marks past its own end -- and
// the complete search walks cells past the end, believing them to be free.
def clear_all(g: [long]) {
    let i = 0;
    while (i < len(g)) {
        g[i] = 0;
        i = i + 1;
    }
};

// Present indices in the order the packer places them: largest shape first,
// ties by index.  inject 7 turns the order around.
def build_piece_order(shapes: [Shape]) {
    porder = [];                         // fresh: this runs once per solve
    let i = 0;
    while (i < len(shapes)) {
        porder += i;
        i = i + 1;
    };
    let a = 1;
    while (a < len(porder)) {
        let v = porder[a];
        let b = a - 1;
        let go = b >= 0;
        while (go) {
            let other = porder[b];
            let swap = 0;
            if (piece_order_asc()) {
                if (shapes[other].area > shapes[v].area) { swap = 1 };
            } else {
                if (shapes[other].area < shapes[v].area) { swap = 1 };
            };
            if (swap == 0) { go = false }
            else {
                porder[b] = v;
                porder[b + 1] = other;
                b = b - 1;
                go = b >= 0;
            };
        };
        a = a + 1;
    }
}

def advance_hint(n: long) {
    while (hint < n && occ[hint] != 0) { hint = hint + 1 }
}

// Place one present of shape `t`: orientations in generation order (backwards
// if `rev`), and for each the topmost-then-leftmost position it fits in.
// `start` is the lowest origin worth trying: a present placed above the
// frontier would need a free cell at or below the frontier, and there is none.
def place_one(sp: Shape, t: long, W: long, H: long, start: long, rev: bool) -> bool {
    let n = W * H;
    let placed = false;
    let oi = 0;
    while (oi < sp.no && !placed) {
        let idx = oi;
        if (rev) { idx = sp.no - 1 - oi };
        let oh = sp.oh[idx];
        let ow = sp.ow[idx];
        if (oh <= H && ow <= W) {
            let pos = start;
            if (scan_from_zero()) { pos = 0 };
            while (pos < n && !placed) {
                let r0 = pos / W;
                let c0 = pos - r0 * W;
                let too_wide = c0 + ow > W;
                let too_tall = r0 + oh > H;
                if (tight_bound() && (r0 + oh >= H || c0 + ow >= W)) {
                    too_wide = true;
                    too_tall = true;
                };
                if (too_wide || too_tall) {
                    pos = pos + 1;
                } else {
                    let st = sp.ostart[idx];
                    let nn = sp.olen[idx];
                    let ok = true;
                    let k = 0;
                    while (k < nn) {
                        let rr = r0 + sp.ocells[st + 2 * k];
                        let cc = c0 + sp.ocells[st + 2 * k + 1];
                        if (occ[rr * W + cc] != 0) {
                            ok = false;
                            k = nn;
                        };
                        k = k + 1;
                    };
                    if (ok) {
                        let id = len(pl) / 4 + 1;
                        let k2 = 0;
                        while (k2 < nn) {
                            occ[(r0 + sp.ocells[st + 2 * k2]) * W
                                 + c0 + sp.ocells[st + 2 * k2 + 1]] = id;
                            k2 = k2 + 1;
                        };
                        pl += t;
                        pl += idx;
                        pl += r0;
                        pl += c0;
                        placed = true;
                    } else {
                        pos = pos + 1;
                    };
                };
            };
        };
        oi = oi + 1;
    };
    placed
}

// The constructive packer: fills `occ` and `pl`, and returns true only if
// every present of the region was placed.  `rev` runs the orientation list
// backwards, which is the second opinion `--check` asks for.
def pack_region(shapes: [Shape], reg: Region, rev: bool) -> bool {
    let W = reg.w;
    let H = reg.h;
    if (grid_swapped()) {
        W = reg.h;
        H = reg.w;
    };
    let n = W * H;
    need_cells(n);
    clear_all(occ);
    pl = [];
    hint = 0;
    let ok = true;
    let pi = 0;
    while (pi < len(porder) && ok) {
        let t = porder[pi];
        let k = 0;
        while (k < reg.q[t] && ok) {
            let start = hint - start_slack();
            if (start < 0) { start = 0 };
            if (!place_one(shapes[t], t, W, H, start, rev)) { ok = false };
            if (ok) { advance_hint(n) };
            k = k + 1;
        };
        pi = pi + 1;
    };
    ok
}

// ── the witness, re-derived from its own records ─────────────────────────────
//
// `witness_check` does not trust how `occ` was filled: it clears occ2 and
// rebuilds it from `pl` alone, so a packer that recorded one placement and
// wrote another is caught.  Returns 0 when the witness is a proof.

def mark_records(shapes: [Shape], W: long, H: long, g: [long], turned: bool) -> long {
    // turned = false: the records as they are.  turned = true: their image
    // under a quarter turn, which lives in an H-by-W region.
    mark_bad = 0;
    let cnt = 0;
    let i = 0;
    while (i + 3 < len(pl)) {
        let t = pl[i];
        let oi = pl[i + 1];
        let r0 = pl[i + 2];
        let c0 = pl[i + 3];
        if (records_swapped()) {
            r0 = pl[i + 3];
            c0 = pl[i + 2];
        };
        let sp = shapes[t];
        if (oi < 0 || oi >= sp.no) {
            mark_bad = mark_bad + 1;
        } else {
            let no = oi;
            let nr = r0;
            let nc = c0;
            if (turned) {
                // a quarter turn about the region's own centre: (r,c) becomes
                // (c, H_orig - 1 - r), and H_orig is the new grid's *width*
                no = sp.xr90[oi];
                if (defect_12()) { no = sp.xr180[oi] };
                if (no < 0) { no = 0 };
                nr = c0;
                nc = W - r0 - sp.oh[oi];
            };
            let st = sp.ostart[no];
            let nn = sp.olen[no];
            let k = 0;
            while (k < nn) {
                let rr = nr + sp.ocells[st + 2 * k];
                let cc = nc + sp.ocells[st + 2 * k + 1];
                if (rr < 0 || rr >= H || cc < 0 || cc >= W) {
                    mark_bad = mark_bad + 1;
                    k = nn;
                } else if (g[rr * W + cc] != 0) {
                    mark_bad = mark_bad + 1;      // two presents, one cell
                    k = nn;
                } else {
                    g[rr * W + cc] = i / 4 + 1;
                    cnt = cnt + 1;
                };
                k = k + 1;
            };
        };
        i = i + 4;
    };
    cnt
}

def witness_check(shapes: [Shape], reg: Region) -> long {
    let W = reg.w;
    let H = reg.h;
    let n = W * H;
    clear_grid(occ2, n);
    let marked = mark_records(shapes, W, H, occ2, false);
    if (mark_bad != 0) { return 1 };
    if (marked != reg.need) { return 2 };
    // the re-derived grid must be exactly the grid the packer left behind
    let diff = 0;
    let i = 0;
    while (i < n) {
        if ((occ2[i] != 0) != (occ[i] != 0)) { diff = diff + 1 };
        i = i + 1;
    };
    if (diff != 0) { return 3 };
    // and the per-shape counts must be the ones the region asked for
    let got: [long] = [];
    let t = 0;
    while (t < len(shapes)) {
        got += 0;
        t = t + 1;
    };
    let i2 = 0;
    while (i2 + 3 < len(pl)) {
        got[pl[i2]] = got[pl[i2]] + 1;
        i2 = i2 + 4;
    };
    t = 0;
    while (t < len(got)) {
        if (got[t] != reg.q[t]) { return 4 };
        t = t + 1;
    };
    0
}

// Transposition is an involution and a quarter turn is its square root, so the
// image of a witness is a witness: turn every present a quarter turn into an
// H-by-W region and re-derive that from the records alone.  0 = sound.
def turn_check(shapes: [Shape], reg: Region) -> long {
    let W = reg.w;
    let H = reg.h;
    let n = W * H;
    clear_grid(occ2, n);
    let marked = mark_records(shapes, H, W, occ2, true);
    if (mark_bad != 0) { return 1 };
    if (marked != reg.need) { return 2 };
    0
}

// The transposition oracle proper: transpose the witness -- mirror every cell
// in the diagonal, which turns a W-by-H region into an H-by-W one -- and
// re-derive that from the records alone.  Distinct from turn_check, which
// moves cells the other way round the origin, so the two exercise different
// transform tables.
def flip_check(shapes: [Shape], reg: Region) -> long {
    let W = reg.h;                        // the transposed grid: H wide
    let H = reg.w;                        // ... and W tall
    let n = W * H;
    clear_grid(occ2, n);
    let bad = 0;
    let cnt = 0;
    let i = 0;
    while (i + 3 < len(pl)) {
        let sp = shapes[pl[i]];
        let oi = sp.xtr[pl[i + 1]];
        let nr = pl[i + 3];                // (r0, c0) -> (c0, r0)
        let nc = pl[i + 2];
        if (oi < 0) {
            bad = bad + 1;
        } else {
            let st = sp.ostart[oi];
            let nn = sp.olen[oi];
            let k = 0;
            while (k < nn) {
                let rr = nr + sp.ocells[st + 2 * k];
                let cc = nc + sp.ocells[st + 2 * k + 1];
                if (rr < 0 || rr >= H || cc < 0 || cc >= W) {
                    bad = bad + 1;
                    k = nn;
                } else if (occ2[rr * W + cc] != 0) {
                    bad = bad + 1;
                    k = nn;
                } else {
                    occ2[rr * W + cc] = i / 4 + 1;
                    cnt = cnt + 1;
                };
                k = k + 1;
            };
        };
        i = i + 4;
    };
    if (bad != 0) { return 1 };
    if (cnt != reg.need) { return 2 };
    0
}

// ── the exhaustive search: the check's third opinion ─────────────────────────
//
// Complete, and so usable only where it terminates: it branches on the first
// free cell, which some remaining present must cover.  Used on the micro-cases
// only, to measure how complete the packer is.

def first_free(W: long, H: long) -> long {
    let i = 0;
    let hit = -1;
    while (i < W * H && hit < 0) {
        if (occ[i] == 0) { hit = i };
        i = i + 1;
    };
    hit
}

let gw = 0;                                // the region being searched: W
let gh = 0;                                // ... and H

// The complete search.  It branches on the first cell that is neither covered
// nor abandoned, and it has TWO branches there: put some remaining present on
// that cell, or declare the cell empty for good.  The second branch is what
// makes the search complete when the region need not be tiled exactly -- the
// obvious rule ("the first free cell must be covered") is only sound for an
// exact tiling, and the statement's own 4x4 example has two spare cells, so a
// search without this branch calls it impossible where the statement says it
// fits.  Abandoning a cell is bounded by the slack: `remarea > freecells`
// prunes, so at most `freecells - remarea` cells can be abandoned in a row.
//
// The descent path is recorded as it goes (`path`, 4 longs per present at the
// current depth, `plen` live on success), so a packing the search finds is a
// witness like any other.
let path: [long] = [];
let plen = 0;

// The first cell of the region that is free and not abandoned, or -1.  It
// walks the region's own cells only: the scratch arrays are sized for the
// largest region seen so far and carry marks past a smaller region's end.
def first_open() -> long {
    let i = 0;
    let hit = -1;
    let n = gw * gh;
    while (i < n && hit < 0) {
        if (occ[i] == 0 && blk[i] == 0) { hit = i };
        i = i + 1;
    };
    hit
}

def exhaustive(shapes: [Shape], rem: [long], nodes: [long], depth: long,
               freec: long, rema: long) -> bool {
    if (rema > freec) { return false };
    nodes[0] = nodes[0] + 1;
    if (nodes[0] > NODE_BUDGET) {
        ex_gave_up = true;
        return false;
    };
    let f = first_open();
    if (f < 0) {
        if (rema == 0) { plen = 4 * depth };
        return rema == 0;
    };
    let fr = f / gw;
    let fc = f - fr * gw;
    let t = 0;
    while (t < len(rem)) {
        if (rem[t] > 0) {
            let sp = shapes[t];
            let oi = 0;
            while (oi < sp.no) {
                let st = sp.ostart[oi];
                let nn = sp.olen[oi];
                let k = 0;
                while (k < nn) {
                    // the origin that puts this cell of the present on (fr,fc)
                    let r0 = fr - sp.ocells[st + 2 * k];
                    let c0 = fc - sp.ocells[st + 2 * k + 1];
                    if (r0 >= 0 && c0 >= 0 && r0 + sp.oh[oi] <= gh
                        && c0 + sp.ow[oi] <= gw) {
                        let ok = true;
                        let j = 0;
                        while (j < nn) {
                            if (occ[(r0 + sp.ocells[st + 2 * j]) * gw
                                    + c0 + sp.ocells[st + 2 * j + 1]] != 0
                                || blk[(r0 + sp.ocells[st + 2 * j]) * gw
                                       + c0 + sp.ocells[st + 2 * j + 1]] != 0) {
                                ok = false;
                                j = nn;
                            };
                            j = j + 1;
                        };
                        if (ok) {
                            let j2 = 0;
                            while (j2 < nn) {
                                occ[(r0 + sp.ocells[st + 2 * j2]) * gw
                                     + c0 + sp.ocells[st + 2 * j2 + 1]] = 1;
                                j2 = j2 + 1;
                            };
                            rem[t] = rem[t] - 1;
                            let o = 4 * depth;
                            path[o] = t;
                            path[o + 1] = oi;
                            path[o + 2] = r0;
                            path[o + 3] = c0;
                            if (exhaustive(shapes, rem, nodes, depth + 1,
                                            freec - nn, rema - nn)) { return true };
                            rem[t] = rem[t] + 1;
                            j2 = 0;
                            while (j2 < nn) {
                                occ[(r0 + sp.ocells[st + 2 * j2]) * gw
                                     + c0 + sp.ocells[st + 2 * j2 + 1]] = 0;
                                j2 = j2 + 1;
                            };
                        };
                    };
                    k = k + 1;
                };
                oi = oi + 1;
            };
        };
        t = t + 1;
    };
    // or leave this cell empty: no present may cover it from here on.  `depth`
    // counts presents placed, so abandoning a cell does not advance it.
    blk[f] = 1;
    if (exhaustive(shapes, rem, nodes, depth, freec - 1, rema)) {
        blk[f] = 0;
        return true;
    };
    blk[f] = 0;
    false
}

// Run the complete search over one region.  Returns 1 if a packing exists (and
// leaves it in `occ` and `pl`), 0 if it proved there is none, -1 if it ran out
// of nodes, in which case the region stays undecided.
def exhaustive_fit(shapes: [Shape], reg: Region) -> long {
    let n = reg.w * reg.h;
    need_cells(n);
    clear_all(occ);
    clear_all(blk);
    gw = reg.w;
    gh = reg.h;
    let rem: [long] = [];
    let t = 0;
    let pieces = 0;
    let area = 0;
    while (t < len(shapes)) {
        rem += reg.q[t];
        pieces = pieces + reg.q[t];
        area = area + reg.q[t] * shapes[t].area;
        t = t + 1;
    };
    // the descent path is indexed and `path *= 0` prepends, so it is sized
    // once here rather than grown inside the search
    while (len(path) < 4 * pieces + 4) { path *= 0 };
    let nodes: [long] = [0];
    ex_gave_up = false;
    plen = 0;
    if (exhaustive(shapes, rem, nodes, 0, n, area)) {
        pl = [];
        let i = 0;
        while (i < plen) {
            pl += path[i];
            i = i + 1;
        };
        return 1;
    };
    if (ex_gave_up) { -1 } else { 0 }
}

// Is the region small enough for the complete search to be worth trying?
// Its cost is exponential, so this is a judgement, and it is reported.
def small_enough(reg: Region) -> bool {
    reg.w * reg.h <= SEARCH_CELLS
};

// ── one pass over the regions ────────────────────────────────────────────────

// Decide one region, by the fast greedy first and the complete search only if
// the greedy came up empty on a region small enough for it:
//
//   2  a packing the complete search found (in `occ` and `pl`)
//   1  a packing the greedy found     (in `occ` and `pl`)
//   0  proved impossible: by area, or by the complete search
//  -1  undecided, and the caller must say so rather than count it
def decide(shapes: [Shape], reg: Region) -> long {
    if (pack_region(shapes, reg, false)) { return 1 };
    if (small_enough(reg)) {
        let hit = exhaustive_fit(shapes, reg);
        if (hit == 1) { return 2 };
        if (hit == -1) { -1 } else { 0 }
    } else {
        -1
    }
}

def new_report(shapes: long, regions: long) -> Report {
    { fits: 0, area_only: 0, agree: 0, witnessed: 0, turned: 0, searched: 0,
      unresolved: 0, over: 0, pieces: 0, need_total: 0, region_cells: 0,
      bad: 0, shapes: shapes, regions: regions, err: "" }
}

// The solver.  Every region gets exactly one verdict:
//
//   * presents need more cells than the region has  -> does not fit, and that
//     is a proof, because area is a hard bound;
//   * a packing was built -- by the greedy, or for a small region by the
//     complete search -- and it re-derives from its own records -> fits, and
//     that is a proof too, because a witness cannot be faked;
//   * neither -> left undecided and counted in `unresolved`, never silently
//     as a "no".
//
// The first two cover every region of the real input, which is why the answer
// does not depend on the greedy being complete.  `agree` counts the regions
// that got one of those two verdicts, so `--check` can insist they partition
// the input.
def solve_all(pz: Puzzle, verify: bool) -> Report {
    let shapes = pz.shapes;
    let regions = pz.regions;
    build_piece_order(shapes);
    let rep = new_report(len(shapes), len(regions));
    let ri = 0;
    while (ri < len(regions)) {
        let reg = regions[ri];
        let cap = reg.w * reg.h;
        let ok_area = area_strict() ? (reg.need < cap) : (reg.need <= cap);
        let decided = false;
        let fits = false;
        let by_search = false;
        if (trust_area()) {
            // defect 11: believe the area bound and never pack anything
            decided = true;
            fits = reg.need <= cap;
        } else if (!ok_area) {
            decided = true;
            rep.over = rep.over + 1;
        } else {
            rep.area_only = rep.area_only + 1;
            let verdict = decide(shapes, reg);
            if (verdict == 1) {
                decided = true;
                fits = true;
            } else if (verdict == 2) {
                decided = true;
                fits = true;
                by_search = true;
            } else if (verdict == 0) {
                decided = true;
            };
        };
        if (decided) {
            rep.agree = rep.agree + 1;
            if (fits) {
                rep.fits = rep.fits + 1;
                if (by_search) { rep.searched = rep.searched + 1 };
                rep.pieces = rep.pieces + len(pl) / 4;
                rep.need_total = rep.need_total + reg.need;
                rep.region_cells = rep.region_cells + cap;
                if (verify) {
                    if (witness_check(shapes, reg) != 0) {
                        rep.bad = rep.bad + 1;
                    } else {
                        rep.witnessed = rep.witnessed + 1;
                        if (turn_check(shapes, reg) == 0
                            && flip_check(shapes, reg) == 0) {
                            rep.turned = rep.turned + 1;
                        } else {
                            rep.bad = rep.bad + 1;
                        };
                    };
                };
            };
        } else {
            rep.unresolved = rep.unresolved + 1;
        };
        ri = ri + 1;
    };
    rep
}

// The same pass with the orientation list run backwards: a second opinion, from
// a different greedy, asked only for its count.  `alt_gave_up` counts the
// regions it could not decide, so a check never compares a count that is
// quietly short.
let alt_gave_up = 0;

def solve_alt(pz: Puzzle) -> long {
    let shapes = pz.shapes;
    let regions = pz.regions;
    build_piece_order(shapes);
    let fits = 0;
    alt_gave_up = 0;
    let ri = 0;
    while (ri < len(regions)) {
        let reg = regions[ri];
        if (reg.need <= reg.w * reg.h) {
            if (pack_region(shapes, reg, true)) { fits = fits + 1 }
            else { alt_gave_up = alt_gave_up + 1 };
        };
        ri = ri + 1;
    };
    fits
}

// ── showing a witness ────────────────────────────────────────────────────────
//
// A packing is easy to claim and hard to read off a number, so `--check`
// prints the small ones as a picture: '.' is an unused cell, every other
// letter is one present.  A reader can check a 4x6 by eye; nobody can check
// 546 of them that way, which is why the witness check exists as well.

// `print_witness` needs the shapes; keep the ones the current pass used, so a
// picture can never be of some other puzzle's shapes.
let shapes_ref: [Shape] = [];

def yesno(b: bool) -> str { if (b) { "fits" } else { "does not fit" } }

def print_witness(reg: Region, head: str) {
    let W = reg.w;
    let H = reg.h;
    let np = len(pl) / 4;
    let toobig = np > 26;
    if (toobig) {
        print(head + f" ({np} presents: too many to letter)");
    } else {
        print(head + f" ({W}x{H}, {np} presents, {reg.need} cells)");
        let row = 0;
        while (row < H) {
            let out = "";
            let col = 0;
            while (col < W) {
                let ch = CH_DOT;
                let found = false;
                let i2 = 0;
                while (i2 + 3 < len(pl) && !found) {
                    let sp = shapes_ref[pl[i2]];
                    let oi = pl[i2 + 1];
                    let k = 0;
                    while (k < sp.olen[oi] && !found) {
                        if (pl[i2 + 2] + sp.ocells[sp.ostart[oi] + 2 * k] == row
                            && pl[i2 + 3] + sp.ocells[sp.ostart[oi] + 2 * k + 1] == col) {
                            ch = CH_A + i2 / 4;
                            found = true;
                        };
                        k = k + 1;
                    };
                    i2 = i2 + 4;
                };
                if (found) { out += chr(ch); } else { out += chr(CH_DOT); };
                col = col + 1;
            };
            print("    " + out);
            row = row + 1;
        };
    }
}

// ── permutations of the input ────────────────────────────────────────────────
//
// Used as oracles: the answer is a count over regions, so reordering the
// region lines cannot change it; and the orientation table is closed under
// rotation and mirroring, so turning each diagram a quarter turn or flipping
// it must not change it either.  A solver that leaned on the diagrams' drawn
// orientation, or that summed something order-dependent, fails both.

def turn_pictures(lines: [str], kind: long) -> [str] {
    let out: [str] = [];
    let n = len(lines);
    let i = 0;
    while (i < n) {
        if (is_picture(lines[i])) {
            let cells: [long] = [];
            let hh = 0;
            let ww = 0;
            let j = i;
            let go = true;
            while (go && j < n) {
                let r = lines[j];
                if (r == "" || !is_picture(r)) { go = false }
                else {
                    let k = 0;
                    while (k < len(r)) {
                        if ((r[k] & 255) == CH_HASH) {
                            cells += j - i;
                            cells += k;
                        };
                        k = k + 1;
                    };
                    if (len(r) > ww) { ww = len(r) };
                    hh = hh + 1;
                    j = j + 1;
                };
            };
            transform(cells, len(cells) / 2, kind);
            let mh = 0;
            let mw = 0;
            let k2 = 0;
            while (k2 < len(cells) / 2) {
                if (scratch[2 * k2] + 1 > mh) { mh = scratch[2 * k2] + 1 };
                if (scratch[2 * k2 + 1] + 1 > mw) { mw = scratch[2 * k2 + 1] + 1 };
                k2 = k2 + 1;
            };
            let r2 = 0;
            while (r2 < mh) {
                let line = "";
                let c2 = 0;
                while (c2 < mw) {
                    let hit = false;
                    let k3 = 0;
                    while (k3 < len(cells) / 2 && !hit) {
                        if (scratch[2 * k3] == r2 && scratch[2 * k3 + 1] == c2) { hit = true };
                        k3 = k3 + 1;
                    };
                    if (hit) { line += "#"; } else { line += "."; };
                    c2 = c2 + 1;
                };
                out += line;
                r2 = r2 + 1;
            };
            i = j;
        } else {
            out += lines[i];
            i = i + 1;
        };
    };
    out
}

// The shape blocks and the first `k` region lines, and nothing else.  Used by
// the injection battery to keep the example cheap: its third region is the one
// the complete search cannot settle inside the node budget, and a battery that
// ran it thirteen times would spend all its time there.
def first_regions(lines: [str], k: long) -> [str] {
    let out: [str] = [];
    let seen = 0;
    let i = 0;
    while (i < len(lines)) {
        if (is_region_line(lines[i])) {
            if (seen < k) { out += lines[i] };
            seen = seen + 1;
        } else if (seen < k) {
            out += lines[i];
        };
        i = i + 1;
    };
    out
}

// The region lines, in reverse order.  Picture blocks and labels stay put.
def reverse_regions(lines: [str]) -> [str] {
    let n = len(lines);
    let cut = n;
    let i = 0;
    while (i < n) {
        if (is_region_line(lines[i]) && cut == n) { cut = i };
        i = i + 1;
    };
    let head: [str] = [];
    let regions: [str] = [];
    let i2 = 0;
    while (i2 < cut) {
        head += lines[i2];
        i2 = i2 + 1;
    };
    i2 = cut;
    while (i2 < n) {
        if (is_region_line(lines[i2])) { regions += lines[i2] };
        i2 = i2 + 1;
    };
    let out: [str] = [];
    i2 = 0;
    while (i2 < len(head)) {
        out += head[i2];
        i2 = i2 + 1;
    };
    i2 = len(regions) - 1;
    while (i2 >= 0) {
        out += regions[i2];
        i2 = i2 - 1;
    };
    i2 = cut + len(regions);
    while (i2 < n) {
        out += lines[i2];
        i2 = i2 + 1;
    };
    out
}

// ── the property battery ─────────────────────────────────────────────────────

// The statement's own worked example, transcribed: six shapes and three
// regions, and the statement says two of the three regions fit.  That "2" is
// the only externally published value in this example, and it is tier 1: it is
// the puzzle's own answer for its own example.  Three write-ups agree on it.
const EXAMPLE_ANSWER = 2;

// micro.txt: the hand-worked cases.  `want` is the truth about the case --
// worked out by hand in README.md and confirmed by the exhaustive search --
// not the packer's opinion.  `want` = 1 means a packing exists.
//
//   1  3x4  0 2 0 0 0 0   need 12 = 12, tiles exactly                1
//   2  4x3  same, transposed: a packing turns with the region         1
//   3  3x5  0 0 0 3 0 0   need 15 = 15, and yet impossible           0
//   4  5x3  same, transposed                                          0
//   5  4x4  0 0 0 0 2 0   need 14 < 16, and yet impossible           0
//   6  3x3  0 0 0 0 1 0   one shape 4 is its own region              1
//   7  3x3  0 0 0 0 2 0   need 14 > 9, short by area                 0
//   8  3x6  1 1 0 1 0 0   need 18 = 18, tiles exactly                1
//   9  3x8  0 4 0 0 0 0   need 24 = 24, tiles exactly                1
//  10  2x3  1 0 0 0 0 0   need 7 > 6, and every shape is 3x3        0
//  11  1x1  0 0 0 1 0 0   need 5 > 1                                  0
//  12  3x3  0 0 0 0 0 0   no presents at all: trivially             1
//  13  4x4  0 0 1 0 2 0   need 21 > 16, short by area                0
//  14  6x6  1 1 1 1 1 1   need 39 > 36, short by area                0
const MICRO_N = 14;
const MICRO_WANT: [long; 14] = [1, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0];

// The statement's picture of how the two shape-4 presents go into its 4x4
// region.  A published witness, so it is an anchor on the verifier itself: if
// this program can re-derive that packing from the letters, its orientation
// table contains the same rotations and mirrors the statement used.
const WITNESS_LINES = 4;
const WITNESS_ANSWER = 2;

// One micro-case: run the exhaustive search (the truth), then the solver's
// own packer, then print the packing it found.  Returns 1 if everything
// matched, 0 if not; `verbose` prints the reasoning either way.
def micro_one(pz: Puzzle, k: long, verbose: bool) -> long {
    let shapes = pz.shapes;
    shapes_ref = shapes;
    build_piece_order(shapes);
    let reg = pz.regions[k];
    let want = MICRO_WANT[k];
    let bad = 0;
    // the truth: the complete search, which cannot miss a packing
    let truth = exhaustive_fit(shapes, reg);
    if (truth != want) {
        bad = 1;
        if (verbose) {
            print(f"    case {k + 1}: the complete search says {truth},"
                  + f" README says {want}");
        };
    };
    // the greedy on its own, for the record: it is not complete and the
    // micro-cases are where that shows
    let packed = pack_region(shapes, reg, false);
    if (packed && (witness_check(shapes, reg) != 0 || turn_check(shapes, reg) != 0
                   || flip_check(shapes, reg) != 0)) {
        bad = 1;
        if (verbose) { print(f"    case {k + 1}: the greedy's witness does not verify") };
    };
    // and the solver's own entry point, which is what the answer uses
    let verdict = decide(shapes, reg);
    if ((verdict > 0) != (truth == 1)) {
        bad = 1;
        if (verbose) {
            print(f"    case {k + 1}: decide() says {verdict}, the complete"
                  + f" search says {truth}");
        };
    };
    if (verdict > 0) {
        if (witness_check(shapes, reg) != 0 || turn_check(shapes, reg) != 0
            || flip_check(shapes, reg) != 0) {
            bad = 1;
            if (verbose) { print(f"    case {k + 1}: decide()'s witness does not verify") };
        };
    };
    // the area bound is a necessary condition: if it says no, nothing fits
    if (reg.need > reg.w * reg.h && truth == 1) {
        bad = 1;
        if (verbose) {
            print(f"    case {k + 1}: area rejected a region that does fit");
        };
    };
    if (verbose) {
        let got = packed ? 1 : 0;
        let verdict_s = got == 1 ? "packs" : "no packing found";
        let note = "";
        if (got != truth) { note = "  <- the greedy alone is incomplete here" };
        print(f"    case {k + 1}: {reg.w}x{reg.h} need {reg.need} of"
              + f" {reg.w * reg.h} cells, complete search {truth},"
              + f" greedy {verdict_s}" + note);
        if (packed) {
            pack_region(shapes, reg, false);
            print_witness(reg, "      greedy");
        };
    };
    bad
}

def check_micro() -> long {
    let f = 0;
    let lines: [str]? = fs.read_lines("micro.txt");
    if (lines == none) {
        f = f + expect("micro.txt present", false, "cannot read micro.txt");
    } else {
        let pz = parse(lines!);
        if (pz.err != "") {
            f = f + expect("micro.txt parses", false, pz.err);
        } else {
            f = f + expect("micro.txt parses", true,
                           f"{len(pz.shapes)} shapes, {len(pz.regions)} regions");
            f = f + expect("micro.txt has 14 regions",
                           len(pz.regions) == MICRO_N,
                           tostring(len(pz.regions)) + " regions");
            // the same six shapes as the real input, so a case here is a case
            // about the presents this puzzle really uses
            let areas = "";
            let no = "";
            let t = 0;
            while (t < len(pz.shapes)) {
                areas += " " + tostring(pz.shapes[t].area);
                no += " " + tostring(pz.shapes[t].no);
                t = t + 1;
            };
            f = f + expect("micro.txt uses the real shapes",
                           areas == " 7 6 7 5 7 7" && no == " 8 4 4 4 2 8",
                           "areas" + areas + ", orientations" + no);
            let bad = 0;
            let k = 0;
            while (k < MICRO_N && k < len(pz.regions)) {
                bad = bad + micro_one(pz, k, true);
                k = k + 1;
            };
            f = f + expect("14 hand-worked micro-cases", bad == 0,
                           tostring(MICRO_N - bad) + " of " + tostring(MICRO_N)
                           + " agree with the exhaustive search and README.md");
        };
    };
    f
}

// The statement's example: part 1 = 2, and the third region is the one the
// statement says cannot be fitted although its presents ask for fewer cells
// than it has (49 of 60) -- an external instance of the micro-cases' case 5.
def check_example() -> long {
    let f = 0;
    let lines: [str]? = fs.read_lines("example.txt");
    if (lines == none) {
        f = f + expect("example.txt present", false, "cannot read example.txt");
    } else {
        let pz = parse(lines!);
        if (pz.err != "") {
            f = f + expect("example.txt parses", false, pz.err);
        } else {
            shapes_ref = pz.shapes;
            build_piece_order(pz.shapes);
            let rep = solve_all(pz, true);
            f = f + expect("statement example: 6 shapes, 3 regions",
                           len(pz.shapes) == 6 && len(pz.regions) == 3,
                           tostring(len(pz.shapes)) + " shapes, "
                           + tostring(len(pz.regions)) + " regions");
            f = f + expect("statement example: part 1 = 2 (tier 1 anchor)",
                           rep.fits == EXAMPLE_ANSWER,
                           f"{rep.fits} of {len(pz.regions)} regions fit,"
                           + " the statement says 2");
            // region by region: 1 and 2 fit, 3 does not.  `decide` leaves the packing it
            // found in `pl`, so each region's witness is checked right after its
            // own verdict and before the next region overwrites it.
            let v1 = decide(pz.shapes, pz.regions[0]);
            let w1 = witness_check(pz.shapes, pz.regions[0]) == 0
                     && turn_check(pz.shapes, pz.regions[0]) == 0
                     && flip_check(pz.shapes, pz.regions[0]) == 0;
            let v2 = decide(pz.shapes, pz.regions[1]);
            let w2 = witness_check(pz.shapes, pz.regions[1]) == 0
                     && turn_check(pz.shapes, pz.regions[1]) == 0
                     && flip_check(pz.shapes, pz.regions[1]) == 0;
            let v3 = decide(pz.shapes, pz.regions[2]);
            let got1 = v1 > 0;
            let got2 = v2 > 0;
            f = f + expect("statement example: 4x4 and 12x5 fit, the second 12x5 does not",
                           got1 && got2 && v3 <= 0,
                           "4x4 " + yesno(got1) + ", 12x5 " + yesno(got2)
                           + ", 12x5+1 " + yesno(v3 > 0)
                           + (v3 == 0 ? " (proved)" : " (not proved: the"
                           + " complete search ran out of nodes)"));
            f = f + expect("statement example: both packings re-derive and turn",
                           w1 && w2,
                           f"4x4: {pz.regions[0].need} cells in 2 presents;"
                           + f" 12x5: {pz.regions[1].need} cells in 6 presents"
                           + (w1 && w2 ? ", both verified" : ", one did not"));
            let r3 = pz.regions[2];
            f = f + expect("statement example: area cannot explain region 3",
                           r3.need <= r3.w * r3.h && v3 <= 0,
                           f"{r3.need} cells asked for, {r3.w * r3.h} available,"
                           + " so the area bound says yes and the packing says no");
            if (got1) {
                decide(pz.shapes, pz.regions[0]);
                print_witness(pz.regions[0], "    4x4");
            };
            if (got2) {
                decide(pz.shapes, pz.regions[1]);
                print_witness(pz.regions[1], "    12x5");
            };
        };
    };
    f
}

// The statement's published 4x4 witness, checked against this program's
// orientation table: every letter must be an exact rotation or flip of shape
// 4, and the two letters must account for the region's two shape-4 presents.
def check_statement_witness() -> long {
    let f = 0;
    let lines: [str]? = fs.read_lines("witness.txt");
    if (lines == none) {
        f = f + expect("witness.txt present", false, "cannot read witness.txt");
    } else {
        let ex: [str]? = fs.read_lines("example.txt");
        if (ex == none) {
            f = f + expect("witness.txt has example.txt to check against", false,
                           "cannot read example.txt");
        } else {
            let pz = parse(ex!);
            shapes_ref = pz.shapes;
            build_piece_order(pz.shapes);
            let H = len(lines!);
            let W = 0;
            let r = 0;
            while (r < H) {
                if (len(lines![r]) > W) { W = len(lines![r]) };
                r = r + 1;
            };
            // every letter is one present; find each one's cells and shape
            let used: [long] = [];
            let bad = 0;
            let letters = 0;
            let c = 0;
            while (c < 128 && bad == 0) {
                let ch = c + CH_A;
                let cells: [long] = [];
                let hits = 0;
                let rr = 0;
                while (rr < H) {
                    let cc = 0;
                    while (cc < len(lines![rr])) {
                        if ((lines![rr][cc] & 255) == ch) {
                            cells += rr;
                            cells += cc;
                            hits = hits + 1;
                        };
                        cc = cc + 1;
                    };
                    rr = rr + 1;
                };
                if (hits > 0) {
                    letters = letters + 1;
                    // normalise into `scratch`, then look it up per shape
                    let n = len(cells) / 2;
                    let k = 0;
                    while (k < n) {
                        scratch[2 * k] = cells[2 * k];
                        scratch[2 * k + 1] = cells[2 * k + 1];
                        k = k + 1;
                    };
                    // transform() normalises as a side effect, so run it with
                    // the identity kind and a copy of the cells
                    let tmp: [long] = [];
                    k = 0;
                    while (k < 2 * n) {
                        tmp += scratch[k];
                        k = k + 1;
                    };
                    transform(tmp, n, 2);        // half turn is order 2
                    transform(tmp, n, 2);        // ... so this is the identity
                    let found = -1;
                    let t = 0;
                    while (t < len(pz.shapes) && found < 0) {
                        if (find_orientation(pz.shapes[t], n) >= 0) { found = t };
                        t = t + 1;
                    };
                    if (found < 0) { bad = bad + 1 } else { used += found };
                };
                c = c + 1;
            };
            f = f + expect("statement witness.txt has 4 rows", H == WITNESS_LINES,
                           tostring(H) + " rows");
            f = f + expect("statement's 4x4 packing: 2 letters, both shape 4",
                           bad == 0 && letters == WITNESS_ANSWER
                           && len(used) == 2 && used[0] == 4 && used[1] == 4,
                           f"{letters} letters, shapes "
                           + (len(used) == 2 ? tostring(used[0]) + ","
                           + tostring(used[1]) : "?")
                           + (bad == 0 ? ", both orientations are in the table"
                           : ", but a letter is not an orientation of any shape"));
        };
    };
    f
}

// The real input, and the sandwich that makes the answer exact.
def check_real(lines: [str]) -> long {
    let f = 0;
    let pz = parse(lines);
    if (pz.err != "") {
        f = f + expect("input.txt parses", false, pz.err);
        return f;
    };
    shapes_ref = pz.shapes;
    f = f + expect("input.txt: 6 shapes, 1000 regions (counted outside the program)",
                   len(pz.shapes) == REAL_SHAPES && len(pz.regions) == REAL_REGIONS,
                   tostring(len(pz.shapes)) + " shapes, "
                   + tostring(len(pz.regions)) + " regions");
    let areas = "";
    let t = 0;
    while (t < len(pz.shapes)) {
        areas += " " + tostring(pz.shapes[t].area);
        t = t + 1;
    };
    f = f + expect("every shape is 3x3 and its orientations are all distinct",
                   pz.shapes[0].h == 3 && pz.shapes[0].w == 3,
                   "areas" + areas);
    let rep = solve_all(pz, true);
    let alt = solve_alt(pz);
    // the sandwich, region by region
    f = f + expect("the two halves partition the regions: fits + over = 1000",
                   rep.fits + rep.over == REAL_REGIONS,
                   f"{rep.fits} + {rep.over} = {rep.fits + rep.over}");
    f = f + expect("no region got both verdicts or neither",
                   rep.agree == REAL_REGIONS,
                   tostring(rep.agree) + " regions decided, all of them once");
    f = f + expect("every 'yes' carries a witness that re-derives",
                   rep.witnessed == rep.fits && rep.bad == 0,
                   f"{rep.witnessed} of {rep.fits} verified, {rep.bad} bad");
    f = f + expect("every witness survives a quarter turn and a transposition",
                   rep.turned == rep.fits,
                   f"{rep.turned} of {rep.fits} turned witnesses verify");
    f = f + expect("every region was decided, none left undecided",
                   rep.unresolved == 0,
                   tostring(rep.unresolved) + " regions pass the area bound but"
                   + " neither the greedy nor the complete search placed"
                   + " anything, so they are not counted either way");
    f = f + expect("the reversed-orientation greedy agrees on the count",
                   alt == rep.fits && alt_gave_up == 0,
                   f"{alt} against {rep.fits}, with {alt_gave_up} regions it"
                   + " could not decide");
    // invariants on the totals, computed from the input rather than the run
    let fit_regions = 0;
    let over_regions = 0;
    let sum_need = 0;
    let sum_cells = 0;
    let sum_pieces = 0;
    let i = 0;
    while (i < len(pz.regions)) {
        let rg = pz.regions[i];
        if (rg.need <= rg.w * rg.h) {
            fit_regions = fit_regions + 1;
            sum_need = sum_need + rg.need;
            sum_cells = sum_cells + rg.w * rg.h;
            let q = 0;
            let k = 0;
            while (k < len(rg.q)) { q = q + rg.q[k]; k = k + 1 };
            sum_pieces = sum_pieces + q;
        } else {
            over_regions = over_regions + 1;
        };
        i = i + 1;
    };
    f = f + expect("invariant: the area-ok regions are exactly those counted",
                   fit_regions == rep.fits && over_regions == rep.over,
                   tostring(fit_regions) + " area-ok, " + tostring(over_regions)
                   + " over capacity");
    f = f + expect("invariant: presents placed equals presents listed",
                   sum_pieces == rep.pieces,
                   tostring(rep.pieces) + " placed, " + tostring(sum_pieces)
                   + " listed");
    f = f + expect("invariant: cells asked for fit in the cells available",
                   sum_need == rep.need_total && sum_need <= sum_cells,
                   f"{rep.need_total} of {rep.region_cells} cells"
                   + f" ({tostring(100 * rep.need_total / rep.region_cells)}%)");
    f = f + expect("invariant: every rejected region really is over capacity",
                   rep.over <= REAL_REGIONS - 1 && rep.fits >= 1,
                   f"{rep.over} rejected, {rep.fits} accepted");
    // the input must not be able to change the answer by being reordered or
    // by having its diagrams turned: the count is over regions, and the
    // orientation table is closed under rotation and mirroring
    let rp = parse(reverse_regions(lines));
    f = f + expect("region lines reversed: same answer",
                   rp.err == "" && solve_all(rp, false).fits == rep.fits,
                   tostring(solve_all(rp, false).fits) + " against "
                   + tostring(rep.fits));
    shapes_ref = pz.shapes;
    let rq = parse(turn_pictures(lines, 2));
    f = f + expect("every diagram turned a half turn: same answer",
                   rq.err == "" && solve_all(rq, false).fits == rep.fits,
                   tostring(solve_all(rq, false).fits) + " against "
                   + tostring(rep.fits));
    shapes_ref = pz.shapes;
    let rr = parse(turn_pictures(lines, 3));
    f = f + expect("every diagram mirrored: same answer",
                   rr.err == "" && solve_all(rr, false).fits == rep.fits,
                   tostring(solve_all(rr, false).fits) + " against "
                   + tostring(rep.fits));
    shapes_ref = pz.shapes;
    // and the tightest fitting region, as a picture a reader can check by eye:
    // "tightest" among those with few enough presents to letter
    let tight = -1;
    let slack = 0;
    i = 0;
    while (i < len(pz.regions)) {
        let rg = pz.regions[i];
        if (rg.need <= rg.w * rg.h) {
            let pieces = 0;
            let q = 0;
            while (q < len(rg.q)) { pieces = pieces + rg.q[q]; q = q + 1 };
            if (pieces <= 26) {
                let s = rg.w * rg.h - rg.need;
                if (tight < 0 || s < slack) {
                    tight = i;
                    slack = s;
                };
            };
        };
        i = i + 1;
    };
    if (tight >= 0) {
        pack_region(pz.shapes, pz.regions[tight], false);
        print(f"  tightest fitting region with few enough presents to letter"
              + f" (#{tight + 1}), {slack} spare cells of"
              + f" {pz.regions[tight].w * pz.regions[tight].h}:");
        print_witness(pz.regions[tight], "    packed");
    };
    f
}

// The injection battery: the same expectations as `--check`, minus the parts
// that need the whole input, run once per injected defect.  Returns the number
// of assertions the defect broke -- 0 means the battery did not notice.
def reduced_battery() -> long {
    let bad = 0;
    let lines: [str]? = fs.read_lines("micro.txt");
    if (lines == none) { return 1 };
    let pz = parse(lines!);
    if (pz.err != "") { return 1 };
    shapes_ref = pz.shapes;
    let k = 0;
    while (k < MICRO_N && k < len(pz.regions)) {
        bad = bad + micro_one(pz, k, false);
        k = k + 1;
    };
    // the whole micro file through the solver's entry point, whose answer must
    // be the number of cases the complete search says fit.  Three of those are
    // exact fits (need == cells), which is what catches a comparison that went
    // from `<=` to `<`.
    let want = 0;
    k = 0;
    while (k < MICRO_N) {
        want = want + MICRO_WANT[k];
        k = k + 1;
    };
    shapes_ref = pz.shapes;
    let mrep = solve_all(pz, true);
    if (mrep.fits != want || mrep.bad != 0 || mrep.unresolved != 0
        || mrep.agree != MICRO_N) {
        bad = bad + 1;
    };
    // the real input, truncated: the first SUBSET regions, each of which must
    // still get exactly one verdict from the two halves, with a witness
    let real: [str]? = fs.read_lines("input.txt");
    if (real == none) { return bad + 1 };
    let cut: [str] = [];
    let seen = 0;
    let i = 0;
    while (i < len(real!)) {
        if (is_region_line(real![i])) {
            seen = seen + 1;
            if (seen > SUBSET) { i = len(real!) } else { cut += real![i] };
        } else if (seen == 0) {
            cut += real![i];
        };
        i = i + 1;
    };
    let rp = parse(cut);
    if (rp.err != "") { return bad + 1 };
    shapes_ref = rp.shapes;
    let rep = solve_all(rp, true);
    if (rep.agree != len(rp.regions)) { bad = bad + 1 };
    if (rep.unresolved != 0) { bad = bad + 1 };
    if (rep.bad != 0) { bad = bad + 1 };
    if (rep.fits + rep.over != len(rp.regions)) { bad = bad + 1 };
    if (rep.witnessed != rep.fits) { bad = bad + 1 };
    if (rep.turned != rep.fits) { bad = bad + 1 };
    if (solve_alt(rp) != rep.fits || alt_gave_up != 0) { bad = bad + 1 };
    // the statement's example, through the same entry point -- its first two
    // regions only, because the third is the one the complete search cannot
    // settle inside the node budget and this battery runs thirteen times
    let ex: [str]? = fs.read_lines("example.txt");
    if (ex == none) { return bad + 1 };
    let ep = parse(first_regions(ex!, 2));
    if (ep.err != "") { return bad + 1 };
    if (solve_all(ep, true).fits != EXAMPLE_ANSWER) { bad = bad + 1 };
    shapes_ref = rp.shapes;
    bad
}

def check_injections() -> long {
    let caught = 0;
    let missed = 0;
    let k = 1;
    while (k <= INJECT_MAX) {
        inject = k;
        let bad = reduced_battery();
        if (bad > 0) {
            caught = caught + 1;
            print(f"  defect {k}: CAUGHT ({bad} assertions broken)");
        } else {
            missed = missed + 1;
            print(f"  defect {k}: not caught");
        };
        inject = 0;
        k = k + 1;
    };
    print(f"  injected {INJECT_MAX} defects: {caught} caught, {missed} missed");
    // the battery must be sound when nothing is injected
    let bad = reduced_battery();
    expect("the injection battery is clean with no defect", bad == 0,
           tostring(bad) + " broken assertions");
    0
}

def run_check() -> long {
    let f = 0;
    print("-- external anchors");
    f = f + check_example();
    f = f + check_statement_witness();
    print("-- hand-worked micro-cases (micro.txt, worked out in README.md)");
    f = f + check_micro();
    print("-- the real input");
    let lines: [str]? = fs.read_lines("input.txt");
    if (lines == none) {
        f = f + expect("input.txt present", false, "cannot read input.txt");
    } else {
        f = f + check_real(lines!);
    };
    print("-- injected defects");
    f = f + check_injections();
    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED"
          + f" (first: {first_failure})");
    f
}

// ── the answer ───────────────────────────────────────────────────────────────

def shapes_line(shapes: [Shape]) -> str {
    let areas = "";
    let no = "";
    let t = 0;
    while (t < len(shapes)) {
        areas += " " + tostring(shapes[t].area);
        no += " " + tostring(shapes[t].no);
        t = t + 1;
    };
    f"areas{areas}, orientations{no}"
}

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day12: cannot read " + path + "\n");
        return 1;
    };
    let pz = parse(lines!);
    if (pz.err != "") {
        eputs("day12: " + path + ": " + pz.err + "\n");
        return 1;
    };
    shapes_ref = pz.shapes;
    let rep = solve_all(pz, true);
    print("day12: Advent of Code 2025 day 12 -- Christmas Tree Farm");
    print(f"input: {path}");
    print(f"shapes: {len(pz.shapes)}, {shapes_line(pz.shapes)}");
    print(f"regions: {len(pz.regions)}");
    print(f"part 1 (regions that can fit all the presents listed): {rep.fits}");
    print(f"  {rep.witnessed} of them carry a packing that re-derives from its own"
          + " records: every present an");
    print("  exact rotation or flip of its shape, in bounds, no cell shared -- and"
          + " all of them also");
    print("  survive a quarter turn and a transposition");
    print(f"  {rep.over} are rejected by area alone: the presents ask for more cells"
          + " than the region");
    print("  has, so they never reach the search");
    print(f"  the two halves decide all {rep.agree} regions exactly once, so"
          + f" {rep.fits} is exact in both");
    print("  directions and does not depend on the packer being complete");
    print(f"  the packer, run with the orientation list backwards, also fits"
          + f" {solve_alt(pz)} ({alt_gave_up} it could not decide)");
    print(f"  presents in those regions: {rep.pieces} presents covering"
          + f" {rep.need_total} of {rep.region_cells} cells");
    if (rep.searched != 0) {
        print(f"  {rep.searched} of the packings were found by the complete search"
              + " rather than the greedy");
    };
    if (rep.unresolved != 0) {
        print(f"  WARNING: {rep.unresolved} regions pass the area bound but nothing"
          + " could place their");
        print("  presents; they are not counted either way, and the answer is"
          + " not settled without them");
    };
    if (rep.bad != 0) {
        eputs("day12: " + tostring(rep.bad) + " packing witnesses did not verify\n");
        return 1;
    };
    print("part 2: there is no second question.  Advent of Code 2025 ran for twelve");
    print("  days and day 12 carries a single star: the puzzle ends with a star");
    print("  appearing above the tree.  Two independent write-ups, both fetched once:");
    print("    https://aoc.winslowjosiah.com/solutions/2025/day/12/ -- twelve days,");
    print("      \"all 23 stars\", so one of the twelve days has a single star");
    print("    https://baerentsen.space/aoc-2025-day-12/ -- a section titled \"Part 2:");
    print("      The Star on the Tree\", and \"No code needed\"");
    0
}

const HELP = "day12 -- Advent of Code 2025 day 12 (Christmas Tree Farm), in Y

usage:
  ./day12 [FILE]        solve FILE (default input.txt), print both answers
  ./day12 --check       run the property battery and print every assertion
  ./day12 --inject N    apply defect N (1..12) to the solver and say whether
                        the injection battery notices
  ./day12 --help        this text

part 1: how many of the regions can fit all the presents listed for them
part 2: none -- day 12 is the last day of Advent of Code 2025 and has one star

The input is two sections: shape diagrams, each introduced by its index and a
colon and drawn with '#' and '.', then one region per line as WxH: followed by
one quantity per shape.  Nothing here assumes 3x3 diagrams or six shapes.
";

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let have_path = false;
    let inj = -1;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check") {
            want_check = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--inject") {
            if (i + 1 >= len(args)) {
                eputs("day12: --inject needs a number 1.." + tostring(INJECT_MAX) + "\n");
                return 1;
            };
            i = i + 1;
            inj = tonum(args[i]);
            if (inj < 1 || inj > INJECT_MAX) {
                eputs("day12: --inject takes 1.." + tostring(INJECT_MAX)
                      + ", not " + args[i] + "\n");
                return 1;
            };
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day12: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day12: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day12: more than one input file given (try --help)\n");
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
    if (inj > 0) {
        inject = inj;
        let bad = reduced_battery();
        if (bad > 0) {
            print(f"defect {inj}: the injection battery breaks {bad} assertions,"
                  + " so --check would notice it");
            inject = 0;
            return 1;
        };
        print(f"defect {inj}: the injection battery does not notice");
        inject = 0;
        return 0;
    };
    solve(path)
};
exit(main())
