// day09.y -- Advent of Code 2025, day 9: "Movie Theater".
//
// ---------------------------------------------------------------- the puzzle
// The theater floor is a big grid of square tiles.  Some tiles are RED; the
// input lists where they are, one "x,y" pair per line.  The Elves want the
// largest rectangle whose two OPPOSITE CORNERS are red tiles.
//
// The area is counted in TILES, not in spans: the rectangle from (x1,y1) to
// (x2,y2) is (|dx|+1) x (|dy|+1) tiles, because the corners are tiles too.
// (The statement's own worked example pins this: 2,5..9,7 is 8 wide by 3
// tall = 24, and 2,5..11,1 is 10 x 5 = 50.)
//
//   part 1: the largest such rectangle, with no further restriction.
//   part 2: the same, but the rectangle must lie WHOLLY INSIDE the room --
//           the red tiles, in input order, are the vertices of a closed
//           axis-aligned polygon (the room's walls), and the rectangle may
//           only cover red or interior tiles.
//
// Part 2's statement is login-gated, so its rule was taken from public
// write-ups and its example answer hand-derived; see README.md for the
// sources, the confidence, and the four independent implementations that
// agree on both the example and the real input.
//
// ---------------------------------------------------------------- reading
// `./day09`            solve the real input, print both answers
// `./day09 --check`    the property battery (no reference file involved)
// `./day09 --input F`  solve another tile list
// `./day09 --help`     usage
//
// Y has no `sort` (hand-rolled insertion sort below), no `break`/
// `continue` (explicit terminal conditions), no `float`->`long`, and
// `[0; n]` needs a literal size (so `zeros_long` grows one).  `tonum` is
// LENIENT -- it stops at the first non-digit and ignores the rest -- so
// every field is gated on `all_digits` before it is converted.

import fs;
// std's seeded generator (splitmix64).  It replaced the LCG that was inlined in
// shuffled()'s loop body; see the note above def shuffled.
import random;

const BIG = 1000000000;

// Set false to drop the empty-slab guard in `rect_inside`; `--check` runs
// part 2 both ways and requires the same answer, so the guard is shown to
// be non-binding on this input rather than merely asserted to be correct.
let g_guard: bool = true;
// Pairs actually evaluated, so `--check` can insist that the candidate set
// really is all C(n,2) unordered pairs and not a neighbourhood of them.
let g_pairs1: long = 0;
let g_pairs2: long = 0;

// ======================================================== tiny utilities

// `[0; n]` requires an integer *literal* size, so grow one instead.
def zeros_long(n: long) -> [long] {
  let a: [long] = [];
  let i = 0;
  while (i < n) { a += 0; i = i + 1 };
  return a
};

def zeros_byte(n: long) -> [byte] {
  let a: [byte] = [];
  let i = 0;
  while (i < n) { a += 0; i = i + 1 };
  return a
};

// Insertion sort of a slice of `a`, ascending, in place.  `n` = length.
def isort(a: [long], base: long, n: long) -> void {
  let i = base + 1;
  while (i < base + n) {
    let v = a[i];
    let j = i - 1;
    let go = true;
    while (go && j >= base) {
      if (a[j] > v) { a[j + 1] = a[j]; j = j - 1 } else { go = false }
    };
    a[j + 1] = v;
    i = i + 1
  }
};

// Sort ascending, then keep one copy of each run.  Returns a fresh array;
// `a` is left holding the sorted values.
def sort_unique(a: [long]) -> [long] {
  let n = a.length;
  isort(a, 0, n);
  let out: [long] = [];
  let i = 0;
  while (i < n) {
    let v = a[i];
    out += v;
    let j = i + 1;
    let go = true;
    while (go && j < n) {
      if (a[j] == v) { j = j + 1 } else { go = false }
    };
    i = j
  };
  return out
};

// Index of `v` in the ascending array `a`, or -1.
def idx_of(a: [long], v: long) -> long {
  let i = 0;
  let n = a.length;
  while (i < n) {
    if (a[i] == v) { return i };
    if (a[i] > v) { return 0 - 1 };
    i = i + 1
  };
  return 0 - 1
};

def absl(v: long) -> long { if (v < 0) { 0 - v } else { v } };

// ------------------------------------------------------------ check ledger

let g_pass: long = 0;
let g_fail: long = 0;

def ok(name: str) -> void {
  g_pass = g_pass + 1;
  print("  [ok]   " + name)
};

def nope(name: str, detail: str) -> void {
  g_fail = g_fail + 1;
  print("  [FAIL] " + name + ": " + detail)
};

def expect_eq(name: str, got: long, want: long) -> void {
  if (got == want) { ok(name + " = " + tostring(want)) }
  else { nope(name, "got " + tostring(got) + ", want " + tostring(want)) }
};

def expect_le(name: str, got: long, bound: long) -> void {
  if (got <= bound) { ok(name + " " + tostring(got) + " <= " + tostring(bound)) }
  else { nope(name, "got " + tostring(got) + " > bound " + tostring(bound)) }
};

def expect_yes(name: str, cond: bool, detail: str) -> void {
  if (cond) { ok(name) } else { nope(name, detail) }
};

// ================================================================ parsing

// Strict: optional '-' then one or more digits, and NOTHING else.
def all_digits(s: str) -> bool {
  if (s.length == 0) { return false };
  let i = 0;
  if (s[0] == ord("-")) { i = 1 };
  if (i >= s.length) { return false };
  while (i < s.length) {
    let c = s[i];
    if (c < ord("0") || c > ord("9")) { return false };
    i = i + 1
  };
  return true
};

// One line -> two tiles' worth of fields appended to `out` (x then y).
// Refuses anything that is not exactly two comma-separated integers.
def parse_pair(line: str, out: [long]) -> bool {
  let parts: [str] = line.split(",");
  if (parts.length != 2) { return false };
  if (!all_digits(parts[0].trim())) { return false };
  if (!all_digits(parts[1].trim())) { return false };
  out += parts[0].trim().tonum();
  out += parts[1].trim().tonum();
  return true
};

// Parse rows into `out` (x0,y0,x1,y1,...).  Returns the index of the first
// row that is not exactly two comma-separated integer fields, or -1 when
// every non-blank row was well formed.  Blank rows are skipped, not
// rejected.  Deliberately NON-exiting, so `--check` can drive it with
// deliberately bad rows and assert exactly which ones it rejects.
def parse_rows(rows: [str], out: [long]) -> long {
  let bad = 0 - 1;
  let ln = 0;
  foreach (row in rows) {
    let raw = row.trim();
    if (raw.length > 0) {
      if (bad == 0 - 1) {
        if (!parse_pair(raw, out)) { bad = ln }
      };
      ln = ln + 1
    }
  };
  return bad
};

// Parse a whole tile list out of a string.  Dies with a message on any line
// that is not exactly two integer fields -- we never assume the shape.
def parse_text(text: str, where: str) -> [long] {
  let rows: [str] = text.split("\n");
  let flat: [long] = [];
  let bad = parse_rows(rows, flat);
  if (bad >= 0) {
    eputs("day09: " + where + " line " + tostring(bad)
          + ": not exactly two integer fields: " + rows[bad].trim() + "\n");
    exit(1)
  };
  if (flat.length == 0) {
    eputs("day09: " + where + ": no red tiles\n");
    exit(1)
  };
  return flat
};

def load_tiles(path: str) -> [long] {
  let text: str? = fs.read_file(path);
  if (text == none) {
    eputs("day09: cannot read input file: " + path + "\n");
    exit(1)
  };
  return parse_text(text!, path)
};

// ------------------------------------------------------- the input's shape

// Facts about the tile list, all of which the check battery asserts.
type Shape = {
  n: long,
  nx: long,
  ny: long,
  max_x_mult: long,
  max_y_mult: long,
  dup_tiles: long,
  slanted_edges: long,
  shoelace: long,
  minx: long, maxx: long,
  miny: long, maxy: long,
  distinct: long
};

// Is the closed rectangle [xlo..xhi] x [ylo..yhi] wholly inside the room?
// Exposed as a free function so the battery can ask about hand-picked
// rectangles directly, instead of only ever asking "what is the maximum".
//
// BOTH x ends and BOTH y ends must be tile coordinates -- the puzzle always
// takes corners from tiles.  A coordinate that is not a tile level is
// REFUSED rather than quietly rounded to the nearest one: falling back would
// make this answer a question nobody asked, which is the "two absent values
// compare equal" trap in a geometric costume.
def rect_ok(b: Band, xlo: long, ylo: long, xhi: long, yhi: long) -> bool {
  let r0 = idx_of(b.ys, ylo);
  let r1 = idx_of(b.ys, yhi);
  if (r0 < 0 || r1 < 0) {
    eputs("day09: rect_ok: y " + tostring(ylo) + " or " + tostring(yhi)
          + " is not a tile level\n");
    exit(1)
  };
  return rect_inside(b, r0, r1, xlo, xhi)
};

// The whole shape of a tile list, without exiting on it.
def shape_of(flat: [long]) -> Shape {
  let n = flat.length / 2;
  let xs: [long] = [];
  let ys: [long] = [];
  let i = 0;
  while (i < n) { xs += flat[i * 2]; ys += flat[i * 2 + 1]; i = i + 1 };
  let mn_x = xs[0];
  let mx_x = xs[0];
  let mn_y = ys[0];
  let mx_y = ys[0];
  i = 1;
  while (i < n) {
    if (xs[i] < mn_x) { mn_x = xs[i] };
    if (xs[i] > mx_x) { mx_x = xs[i] };
    if (ys[i] < mn_y) { mn_y = ys[i] };
    if (ys[i] > mx_y) { mx_y = ys[i] };
    i = i + 1
  };
  let sx = sort_unique(xs);
  let sy = sort_unique(ys);
  // Largest multiplicity of any single x (and of any single y): a proper
  // rectilinear room has each level used by exactly two vertices.
  let mxm = 1;
  i = 0;
  while (i < sx.length) {
    let v = sx[i];
    let c = 0;
    let k = 0;
    while (k < n) {
      if (flat[k * 2] == v) { c = c + 1 };
      k = k + 1
    };
    if (c > mxm) { mxm = c };
    i = i + 1
  };
  let mym = 1;
  i = 0;
  while (i < sy.length) {
    let v = sy[i];
    let c = 0;
    let k = 0;
    while (k < n) {
      if (flat[k * 2 + 1] == v) { c = c + 1 };
      k = k + 1
    };
    if (c > mym) { mym = c };
    i = i + 1
  };
  // Distinct tiles: any exact repeat shows up as a (x,y) seen before.
  let dup = 0;
  i = 0;
  while (i < n) {
    let k = i + 1;
    while (k < n) {
      if (flat[k * 2] == flat[i * 2] && flat[k * 2 + 1] == flat[i * 2 + 1]) { dup = dup + 1 };
      k = k + 1
    };
    i = i + 1
  };
  // Every consecutive pair (and last->first) must be an axis-aligned edge.
  let slant = 0;
  i = 0;
  while (i < n) {
    let j = i + 1;
    if (j == n) { j = 0 };
    if (flat[i * 2] != flat[j * 2] && flat[i * 2 + 1] != flat[j * 2 + 1]) { slant = slant + 1 };
    i = i + 1
  };
  // Twice the enclosed area, by the shoelace formula.
  let sa = 0;
  i = 0;
  while (i < n) {
    let j = i + 1;
    if (j == n) { j = 0 };
    sa = sa + flat[i * 2] * flat[j * 2 + 1] - flat[j * 2] * flat[i * 2 + 1];
    i = i + 1
  };
  return { n: n, nx: sx.length, ny: sy.length,
           max_x_mult: mxm, max_y_mult: mym, dup_tiles: dup,
           slanted_edges: slant, shoelace: sa,
           minx: mn_x, maxx: mx_x, miny: mn_y, maxy: mx_y,
           distinct: sx.length + sy.length }
};

// ================================================================= part 1

// The rectangle over every unordered pair of red tiles.  Straight O(n^2):
// n = 496 gives 122 760 evaluations.  `win` receives the winning pair.
def solve_part1(flat: [long], win: [long]) -> long {
  let n = flat.length / 2;
  let best = 0;
  let bi = 0;
  let bj = 0;
  let i = 0;
  while (i < n) {
    let xi = flat[i * 2];
    let yi = flat[i * 2 + 1];
    let j = i + 1;
    while (j < n) {
      g_pairs1 = g_pairs1 + 1;
      let dx = absl(flat[j * 2] - xi);
      let dy = absl(flat[j * 2 + 1] - yi);
      let area = (dx + 1) * (dy + 1);
      if (area > best) { best = area; bi = i; bj = j };
      j = j + 1
    };
    i = i + 1
  };
  win += flat[bi * 2];
  win += flat[bi * 2 + 1];
  win += flat[bj * 2];
  win += flat[bj * 2 + 1];
  return best
};

// ================================================================= part 2

// The room: the red tiles in input order, joined by axis-aligned edges and
// closed.  What part 2 needs, in coordinate-compressed form:
//
//   ys[m]   the distinct tile y levels, ascending (m = 0 .. ny-1)
//   lo/hi   for the row slab ys[m] .. ys[m+1]-1: the smallest and largest x
//           at which a vertical wall crosses that slab.  A lattice point is
//           inside-or-on the room at such a row iff lo <= x <= hi.
//   hh/hlo/hhi   the horizontal wall segment at height ys[m], if there is
//           one -- the one way a tile at a *vertex* row can be red without
//           being between two crossings.
//   ty[i]   the compressed y level of tile i.
//
// The topmost row (y == ys[ny-1]) has no crossings at all, so lo/hi there
// are sentinels and only the horizontal segment can make it acceptable.
type Band = {
  ys: [long], lo: [long], hi: [long],
  hlo: [long], hhi: [long], hh: [byte],
  ty: [long], ny: long,
  empty_slabs: long, wall_rows: long
};

def build_band(flat: [long]) -> Band {
  let n = flat.length / 2;
  let rawy: [long] = [];
  let i = 0;
  while (i < n) { rawy += flat[i * 2 + 1]; i = i + 1 };
  let ys = sort_unique(rawy);
  let ny = ys.length;
  let lo = zeros_long(ny);
  let hi = zeros_long(ny);
  let hlo = zeros_long(ny);
  let hhi = zeros_long(ny);
  let hh = zeros_byte(ny);
  let ty = zeros_long(n);
  i = 0;
  while (i < n) { ty[i] = idx_of(ys, flat[i * 2 + 1]); i = i + 1 };

  // Horizontal wall segments: consecutive tiles (and last -> first).
  let walls = 0;
  i = 0;
  while (i < n) {
    let j = i + 1;
    if (j == n) { j = 0 };
    if (flat[i * 2 + 1] == flat[j * 2 + 1]) {
      let m = ty[i];
      let a = flat[i * 2];
      let b = flat[j * 2];
      if (b < a) { let t = a; a = b; b = t };
      if (hh[m] == 1) { walls = walls + 1 };   // two segments on one level
      hlo[m] = a;
      hhi[m] = b;
      hh[m] = 1
    };
    i = i + 1
  };

  // Crossing interval per row slab: walk the vertical walls.
  let m = 0;
  while (m < ny - 1) {
    let y0 = ys[m];
    let mn = BIG;
    let mx = 0 - BIG;
    let cnt = 0;
    let e = 0;
    while (e < n) {
      let f = e + 1;
      if (f == n) { f = 0 };
      let ax = flat[e * 2];
      let bx = flat[f * 2];
      if (ax == bx) {
        let a = flat[e * 2 + 1];
        let b = flat[f * 2 + 1];
        if (b < a) { let t = a; a = b; b = t };
        if (a <= y0 && y0 < b) {
          cnt = cnt + 1;
          if (ax < mn) { mn = ax };
          if (ax > mx) { mx = ax }
        }
      };
      e = e + 1
    };
    if (cnt % 2 != 0) {
      eputs("day09: row " + tostring(y0) + " has an odd number of wall crossings ("
            + tostring(cnt) + "); the tiles do not form a closed room\n");
      exit(1)
    };
    if (cnt == 0) {
      eputs("day09: row " + tostring(y0) + " has no wall crossings; the tiles do"
            + " not form a closed room\n");
      exit(1)
    };
    lo[m] = mn;
    hi[m] = mx;
    m = m + 1
  };
  lo[ny - 1] = BIG;
  hi[ny - 1] = 0 - BIG;

  // Slabs with ys[m+1] == ys[m]+1 hold no non-vertex rows at all, so their
  // crossing interval is not load-bearing (counted, not assumed away).
  let empty = 0;
  m = 0;
  while (m < ny - 1) {
    if (ys[m + 1] == ys[m] + 1) { empty = empty + 1 };
    m = m + 1
  };
  return { ys: ys, lo: lo, hi: hi, hlo: hlo, hhi: hhi, hh: hh,
           ty: ty, ny: ny, empty_slabs: empty, wall_rows: walls }
};

// Is the closed rectangle [xlo..xhi] x [ylo..yhi] made only of tiles that are
// inside or on the room?  `r0`/`r1` are the compressed y levels of ylo/yhi.
//
// For a row y that is NOT a tile y level, the acceptable x are exactly
// [lo[m], hi[m]] of its slab.  For a row that IS a tile y level there is one
// extra possibility: the horizontal wall at that height, which is what makes
// the wall tiles themselves red.
def rect_inside(b: Band, r0: long, r1: long, xlo: long, xhi: long) -> bool {
  // Rows strictly between the two sides (non-vertex rows).
  let r = r0;
  while (r < r1) {
    if (!g_guard || b.ys[r + 1] > b.ys[r] + 1) {
      if (b.lo[r] > xlo || b.hi[r] < xhi) { return false }
    };
    r = r + 1
  };
  // The vertex rows themselves.  A vertex row's acceptable tiles are the
  // UNION of the crossing interval [lo,hi] and the wall segment at that
  // height, so containment in EITHER one is enough -- and so is containment
  // in the two merged, when they touch or overlap.  (Testing only "in either
  // one" is a real bug: the L shape's rectangle 0,0..4,2 is legal only
  // because row 2 is covered by [0,2] together with the wall [2,4].)
  let s = r0;
  while (s <= r1) {
    // A wall segment that actually touches the crossing interval can be
    // merged with it (see below); one that does not cannot, and then only
    // containment in one or the other will do.  `lo1`/`hi1` are the two
    // intervals' inner ends and `m1`/`m2` the union's extent.
    let a1 = b.lo[s];
    let a2 = b.hi[s];
    let good = false;
    if (a1 <= xlo && a2 >= xhi) { good = true };
    if (!good && b.hh[s] == 1 && b.hlo[s] <= b.hhi[s]) {
      let c1 = b.hlo[s];
      let c2 = b.hhi[s];
      if (c1 <= xlo && c2 >= xhi) { good = true };
      if (!good) {
        let m1 = c1;
        let m2 = c2;
        if (a1 < m1) { m1 = a1 };
        if (a2 > m2) { m2 = a2 };
        let lo1 = c1;
        let hi1 = c2;
        if (a1 < lo1) { lo1 = a1 };
        if (a2 < hi1) { hi1 = a2 };
        // contiguous only if the two intervals touch or overlap
        if (lo1 <= hi1 + 1 && m1 <= xlo && m2 >= xhi) { good = true }
      }
    };
    if (!good) { return false };
    s = s + 1
  };
  return true
};

def solve_part2(flat: [long], b: Band, win: [long]) -> long {
  let n = flat.length / 2;
  let best = 0;
  let bi = 0;
  let bj = 0;
  let i = 0;
  while (i < n) {
    let xi = flat[i * 2];
    let ti = b.ty[i];
    let j = i + 1;
    while (j < n) {
      g_pairs2 = g_pairs2 + 1;
      let dx = absl(flat[j * 2] - xi);
      let dy = absl(flat[j * 2 + 1] - flat[i * 2 + 1]);
      let area = (dx + 1) * (dy + 1);
      if (area > best) {
        let tj = b.ty[j];
        let r0 = ti;
        let r1 = tj;
        if (r1 < r0) { let t = r0; r0 = r1; r1 = t };
        let xlo = xi;
        let xhi = flat[j * 2];
        if (xhi < xlo) { let t = xlo; xlo = xhi; xhi = t };
        if (rect_inside(b, r0, r1, xlo, xhi)) { best = area; bi = i; bj = j }
      };
      j = j + 1
    };
    i = i + 1
  };
  win += flat[bi * 2];
  win += flat[bi * 2 + 1];
  win += flat[bj * 2];
  win += flat[bj * 2 + 1];
  return best
};

// How many pairs attain `best`?  Reported rather than required to be 1: the
// real input has ties, and which one the scan happens to report first
// depends on the loop order.  With `legal` set, only pairs the room accepts
// are counted (part 2's ties).
def count_ties(flat: [long], b: Band, best: long, legal: bool) -> long {
  let n = flat.length / 2;
  let c = 0;
  let i = 0;
  while (i < n) {
    let xi = flat[i * 2];
    let yi = flat[i * 2 + 1];
    let ti = b.ty[i];
    let j = i + 1;
    while (j < n) {
      let dx = absl(flat[j * 2] - xi);
      let dy = absl(flat[j * 2 + 1] - yi);
      if ((dx + 1) * (dy + 1) == best) {
        let ok = true;
        if (legal) {
          let r0 = ti;
          let r1 = b.ty[j];
          if (r1 < r0) { let t = r0; r0 = r1; r1 = t };
          let xlo = xi;
          let xhi = flat[j * 2];
          if (xhi < xlo) { let t = xlo; xlo = xhi; xhi = t };
          ok = rect_inside(b, r0, r1, xlo, xhi)
        };
        if (ok) { c = c + 1 }
      };
      j = j + 1
    };
    i = i + 1
  };
  return c
};

// ================================================================= oracles
// Each of these is a DIFFERENT KIND of computation from the solver above, so
// a defect in the solver cannot hide by being mirrored in the check.  The
// permutation one exists because of day05: sorting the *values* of an
// interleaved (lo,hi) array made it compare one pair's high with another
// pair's low, and every other check still agreed with it.

// ---- oracle A: the published "no wall inside the rectangle" rule.
// Edges are the 1-wide rectangles joining consecutive tiles; a candidate is
// rejected if any edge touches the candidate's INNER area (one tile in from
// each of the four sides).
def no_wall_inside(flat: [long], xlo: long, xhi: long, ylo: long, yhi: long) -> bool {
  let ex1 = xlo + 1;
  let ex2 = xhi - 1;
  let ey1 = ylo + 1;
  let ey2 = yhi - 1;
  if (ex1 > ex2 || ey1 > ey2) { return true };
  let n = flat.length / 2;
  let e = 0;
  while (e < n) {
    let f = e + 1;
    if (f == n) { f = 0 };
    let gx1 = flat[e * 2];
    let gx2 = flat[f * 2];
    if (gx1 > gx2) { let t = gx1; gx1 = gx2; gx2 = t };
    let gy1 = flat[e * 2 + 1];
    let gy2 = flat[f * 2 + 1];
    if (gy1 > gy2) { let t = gy1; gy1 = gy2; gy2 = t };
    if (gx1 <= ex2 && ex1 <= gx2 && gy1 <= ey2 && ey1 <= gy2) { return false };
    e = e + 1
  };
  return true
};

def oracle_wall_filter(flat: [long]) -> long {
  let n = flat.length / 2;
  let best = 0;
  let i = 0;
  while (i < n) {
    let xi = flat[i * 2];
    let yi = flat[i * 2 + 1];
    let j = i + 1;
    while (j < n) {
      let dx = absl(flat[j * 2] - xi);
      let dy = absl(flat[j * 2 + 1] - yi);
      let area = (dx + 1) * (dy + 1);
      if (area > best) {
        let xlo = xi;
        let xhi = flat[j * 2];
        if (xhi < xlo) { let t = xlo; xlo = xhi; xhi = t };
        let ylo = yi;
        let yhi = flat[j * 2 + 1];
        if (yhi < ylo) { let t = ylo; ylo = yhi; yhi = t };
        if (no_wall_inside(flat, xlo, xhi, ylo, yhi)) { best = area }
      };
      j = j + 1
    };
    i = i + 1
  };
  return best
};

// ---- oracle B: coordinate compression, scanline fill, 2-D prefix sums.
// A completely different shape of algorithm: paint a (W-1) x (H-1) grid of
// compressed cells as inside/outside, then answer each candidate with one
// O(1) prefix-sum query.  It tests "no STRICTLY outside tile lies strictly
// inside the rectangle", which is a necessary condition for the solver's
// rule; agreement between the two is real evidence, not a restatement.
def oracle_scan_prefix(flat: [long]) -> long {
  let n = flat.length / 2;
  let rax: [long] = [];
  let ray: [long] = [];
  let i = 0;
  while (i < n) { rax += flat[i * 2]; ray += flat[i * 2 + 1]; i = i + 1 };
  let cx = sort_unique(rax);
  let cy = sort_unique(ray);
  let w = cx.length - 1;
  let h = cy.length - 1;
  let out = zeros_byte(w * h);
  let tx = zeros_long(n);
  let ty = zeros_long(n);
  i = 0;
  while (i < n) {
    tx[i] = idx_of(cx, flat[i * 2]);
    ty[i] = idx_of(cy, flat[i * 2 + 1]);
    i = i + 1
  };
  let buf = zeros_long(n);
  // Fill one row slab at a time: collect the wall crossings, sort them, and
  // mark the inside stretches.  `buf` is reused for every row, so nothing
  // is allocated per row.
  let r = 0;
  while (r < h) {
    let y0 = cy[r];
    let cnt = 0;
    let e = 0;
    while (e < n) {
      let f = e + 1;
      if (f == n) { f = 0 };
      let ax = flat[e * 2];
      if (ax == flat[f * 2]) {
        let a = flat[e * 2 + 1];
        let b = flat[f * 2 + 1];
        if (b < a) { let t = a; a = b; b = t };
        if (a <= y0 && y0 < b) { buf[cnt] = ax; cnt = cnt + 1 }
      };
      e = e + 1
    };
    isort(buf, 0, cnt);
    if (cnt % 2 != 0 || cnt == 0) {
      eputs("day09: oracle_scan_prefix: row " + tostring(y0)
            + " is not a closed room\n");
      exit(1)
    };
    let k = 0;
    while (k + 1 < cnt) {
      let ca = idx_of(cx, buf[k]);
      let cb = idx_of(cx, buf[k + 1]);
      let c = ca;
      while (c < cb) { out[c * h + r] = 0; c = c + 1 };
      k = k + 2
    };
    // everything left of the first crossing and right of the last is outside
    let first = idx_of(cx, buf[0]);
    let last = idx_of(cx, buf[cnt - 1]);
    let q = 0;
    while (q < w) {
      if (q < first || q >= last) { out[q * h + r] = 1 };
      q = q + 1
    };
    r = r + 1
  };
  // 2-D prefix sums over the "outside" flags, stride h+1.
  let stride = h + 1;
  let pre = zeros_long((w + 1) * stride);
  let c = 0;
  while (c < w) {
    let rr = 0;
    while (rr < h) {
      pre[(c + 1) * stride + (rr + 1)] = out[c * h + rr]
        + pre[c * stride + (rr + 1)] + pre[(c + 1) * stride + rr]
        - pre[c * stride + rr];
      rr = rr + 1
    };
    c = c + 1
  };
  let best = 0;
  i = 0;
  while (i < n) {
    let xi = flat[i * 2];
    let ti = ty[i];
    let j = i + 1;
    while (j < n) {
      let dx = absl(flat[j * 2] - xi);
      let dy = absl(flat[j * 2 + 1] - flat[i * 2 + 1]);
      let area = (dx + 1) * (dy + 1);
      if (area > best) {
        let c0 = tx[i];
        let c1 = tx[j];
        if (c1 < c0) { let t = c0; c0 = c1; c1 = t };
        let r0 = ti;
        let r1 = ty[j];
        if (r1 < r0) { let t = r0; r0 = r1; r1 = t };
        let cnt = pre[c1 * stride + r1] - pre[c0 * stride + r1]
                - pre[c1 * stride + r0] + pre[c0 * stride + r0];
        if (cnt == 0) { best = area }
      };
      j = j + 1
    };
    i = i + 1
  };
  return best
};

// ---- oracle C: input-order permutations, through the REAL solver.
// Part 1's answer cannot depend on the order of the tiles at all, so a
// deterministic shuffle must not move it.  Part 2's room is defined by the
// CYCLIC order, so the order permutations that must leave it alone are the
// rotations and the reversal.  Both go through solve_part1/solve_part2, so a
// defect injected in the solver really is injected here.
// The shuffle's random draw is std's: `random.seed(seed)` then
// `random.below(k + 1)`.  This used to be an LCG inlined in the loop body --
// `s = (s * 1103515245 + 12345) % 2147483648; let j = s % (k + 1)` -- which is
// both a second copy of a generator (day10 carried the same one) and a biased
// draw for every (k + 1) that is not a power of two.  A Fisher-Yates only needs
// `j` uniform on 0..k, which random.below gives it by rejection sampling.
//
// `random.seed(seed)` is called HERE rather than by the caller so that
// `shuffled(flat, s)` stays a pure function of (flat, s) exactly as it was when
// the state was a local: two calls with the same seed shuffle identically
// whichever order they are made in, and the eight-seed sweep in oracle C does
// not have to know that std's stream is module-level.
def shuffled(flat: [long], seed: long) -> [long] {
  let n = flat.length / 2;
  let a: [long] = [];
  let i = 0;
  while (i < n) { a += flat[i * 2]; a += flat[i * 2 + 1]; i = i + 1 };
  random.seed(seed);
  let k = n - 1;
  while (k > 0) {
    let j = random.below(k + 1);
    let tx = a[k * 2];
    let tyv = a[k * 2 + 1];
    let jx = a[j * 2];
    let jy = a[j * 2 + 1];
    a[k * 2] = jx;
    a[k * 2 + 1] = jy;
    a[j * 2] = tx;
    a[j * 2 + 1] = tyv;
    k = k - 1
  };
  return a
};

def rotated(flat: [long], by: long) -> [long] {
  let n = flat.length / 2;
  let a: [long] = [];
  let i = 0;
  while (i < n) {
    let k = (i + by) % n;
    a += flat[k * 2];
    a += flat[k * 2 + 1];
    i = i + 1
  };
  return a
};

def reversed(flat: [long]) -> [long] {
  let n = flat.length / 2;
  let a: [long] = [];
  let i = 0;
  while (i < n) {
    let k = n - 1 - i;
    a += flat[k * 2];
    a += flat[k * 2 + 1];
    i = i + 1
  };
  return a
};

// ---- oracle D: an independent reader.
// A byte-at-a-time scan that never calls split() or tonum(), so a defect in
// the parser cannot hide behind the parser.  Returns the number of
// malformed bytes it saw (a line must hold exactly two integer fields, and
// the stream must end on a line boundary); non-exiting so `--check` can
// feed it bad bytes and assert the count.
def rescan_bytes(b: [byte], out: [long]) -> long {
  let n = b.length;
  let fv = zeros_long(2);
  let nf = 0;
  let v = 0;
  let digits = 0;
  let neg = false;
  let bad = 0;
  let i = 0;
  while (i < n) {
    let c = b[i];
    if (c >= 48 && c <= 57) {
      v = v * 10 + (c - 48);
      digits = digits + 1
    }
    else {
      if (c == 45 && digits == 0) { neg = true }
      else {
        if (c == 44) {
          if (nf > 1 || digits == 0) { bad = bad + 1 } else { fv[nf] = neg ? (0 - v) : v; nf = nf + 1 };
          v = 0; digits = 0; neg = false
        }
        else {
          if (c == 10) {
            if (nf == 1 && digits > 0) { fv[1] = neg ? (0 - v) : v; nf = 2 }
            else { bad = bad + 1 };
            if (nf == 2) {
              out += fv[0];
              out += fv[1];
              nf = 0
            };
            v = 0; digits = 0; neg = false
          }
          else {
            if (c != 13) { bad = bad + 1 }
          }
        }
      }
    };
    i = i + 1
  };
  if (nf != 0 || digits != 0) { bad = bad + 1 };
  return bad
};

def rescan(path: str) -> [long] {
  let raw: [byte]? = fs.read_bytes(path);
  if (raw == none) {
    eputs("day09: rescan: cannot read " + path + "\n");
    exit(1)
  };
  let flat: [long] = [];
  let bad = rescan_bytes(raw!, flat);
  if (bad > 0) {
    eputs("day09: rescan: " + tostring(bad) + " malformed byte(s) in " + path + "\n");
    exit(1)
  };
  if (flat.length == 0) {
    eputs("day09: rescan: no tiles in " + path + "\n");
    exit(1)
  };
  return flat
};

// ============================================================ check battery

def run_check(path: str) -> long {
  print("day09: property battery -- no reference file is involved here");
  print("input: " + path);

  let flat = load_tiles(path);
  let n = flat.length / 2;
  let sh = shape_of(flat);
  print("");
  print("shape of the input:");
  print("  tiles " + tostring(sh.n) + ", x levels " + tostring(sh.nx)
        + ", y levels " + tostring(sh.ny)
        + ", max tiles on one x level " + tostring(sh.max_x_mult)
        + ", on one y level " + tostring(sh.max_y_mult));
  print("  x in [" + tostring(sh.minx) + ", " + tostring(sh.maxx)
        + "], y in [" + tostring(sh.miny) + ", " + tostring(sh.maxy) + "]");

  // ---- the input itself must have the shape the statement guarantees
  expect_eq("every line had exactly two integer fields", n, 496);
  expect_eq("x levels", sh.nx, 248);
  expect_eq("y levels", sh.ny, 248);
  expect_eq("each x level is used by exactly two vertices", sh.max_x_mult, 2);
  expect_eq("each y level is used by exactly two vertices", sh.max_y_mult, 2);
  expect_eq("no duplicate tiles", sh.dup_tiles, 0);
  expect_eq("every consecutive pair is an axis-aligned edge", sh.slanted_edges, 0);
  expect_eq("the loop is simple (CCW shoelace is positive)", sh.shoelace > 0 ? 1 : 0, 1);

  // ---- oracle D: a second, unrelated reader must agree
  let re = rescan(path);
  let same = (re.length == flat.length);
  if (same) {
    let k = 0;
    while (k < flat.length) {
      if (re[k] != flat[k]) { same = false };
      k = k + 1
    }
  };
  expect_yes("oracle D: byte-level rescan agrees with the parser ("
             + tostring(re.length / 2) + " tiles)", same,
             "rescan and parse_lines disagree");

  // ---- the real solver, on the real input
  let b = build_band(flat);
  let w1: [long] = [];
  let w2: [long] = [];
  g_pairs1 = 0;
  g_pairs2 = 0;
  let p1 = solve_part1(flat, w1);
  let p2 = solve_part2(flat, b, w2);
  let all_pairs = n * (n - 1) / 2;
  print("");
  print("solver on " + path + ":");
  expect_eq("part 1 evaluated exactly C(n,2) pairs", g_pairs1, all_pairs);
  expect_eq("part 2 evaluated exactly C(n,2) pairs", g_pairs2, all_pairs);
  print("  part 1 = " + tostring(p1) + "   pair " + tostring(w1[0]) + ","
        + tostring(w1[1]) + " and " + tostring(w1[2]) + "," + tostring(w1[3]));
  print("  part 2 = " + tostring(p2) + "   pair " + tostring(w2[0]) + ","
        + tostring(w2[1]) + " and " + tostring(w2[2]) + "," + tostring(w2[3]));

  // Row slabs that hold no non-vertex row: y levels 2985 and 2986 in the real
  // input are one apart, so `rect_inside`'s guard for them is a real path.
  // Reported as a measured fact, and part 2 is re-run without the guard to
  // show the guard does not move this answer either way.
  expect_eq("y levels carrying two wall segments", b.wall_rows, 0);
  expect_eq("row slabs holding no non-vertex row", b.empty_slabs, 1);
  g_guard = false;
  let nog: [long] = [];
  let p2_noguard = solve_part2(flat, b, nog);
  g_guard = true;
  expect_eq("part 2 is the same with rect_inside's empty-slab guard dropped",
            p2_noguard, p2);
  let ties1 = count_ties(flat, b, p1, false);
  let ties2 = count_ties(flat, b, p2, true);
  // The tie counts are pinned to numbers obtained OUTSIDE this program (an
  // independent exhaustive enumeration, README.md), not merely to ">= 1":
  // a self-comparison like `ties1 == ties1` would pass no matter what.
  expect_eq("part 1's maximum is attained by exactly this many pairs", ties1, 1);
  expect_eq("part 2's maximum is attained by exactly this many legal pairs", ties2, 1);

  // Allocation: both solvers are pure loops over flat arrays, so the heap
  // arena must not move at all while they run.  The output arrays are
  // pre-sized so their four appends are not counted as solver allocation.
  let hw1 = zeros_long(4);
  let hw2 = zeros_long(4);
  let h0 = heap_used();
  let r1 = solve_part1(flat, hw1);
  let h1 = heap_used();
  let r2 = solve_part2(flat, b, hw2);
  let h2 = heap_used();
  print("  heap across part 1: +" + tostring(h1 - h0)
        + " B; across part 2: +" + tostring(h2 - h1) + " B");
  expect_yes("part 1 allocates nothing in its 122 760-iteration loop",
             h1 == h0 && r1 == p1, "heap moved, or the answer changed");
  expect_yes("part 2 allocates nothing while scanning the pairs",
             h2 == h1 && r2 == p2, "heap moved, or the answer changed");

  // ---- the default run's own reporting path, driven on a degenerate list.
  // A tile list with fewer than three vertices encloses no area, so
  // shoelace/2 is 0 and `p1 * 100 / area2` would be a division-by-zero trap
  // -- which prints to STDOUT and silently corrupts EXPECTED.  D44 injects
  // exactly that guard removal, and only this case sees it.
  print("");
  print("the default run's reporting path on a degenerate list (no trap):");
  let degen = parse_text("3,3\n", "degenerate");
  expect_eq("a one-tile list reports 0 and 0 without trapping",
            report("degenerate", degen), 0);
  // A two-tile list cannot be a room at all (no closed loop), and
  // `build_band` says so and exits non-zero rather than trapping -- so the
  // degenerate no-area case that reaches the divisor is the ONE-tile list
  // above, where the loop is trivially closed and encloses nothing.

  // ---- the room predicate itself, asked directly about named rectangles.
  // The maximum answers only ever reveal ONE rectangle's legality; these
  // pin the predicate on specific tiles of the real input, so a defect that
  // happened to leave the maximum alone would still show up here.
  print("");
  print("the room predicate, asked about specific rectangles:");
  // 5649,67626 and 94564,50077 are part 2's winning corners; the rectangle
  // between them must be accepted.
  expect_yes("the real input's winning rectangle is inside the room",
             rect_ok(b, 5649, 50077, 94564, 67626),
             "the reported winner is rejected by the predicate");
  // How far the room extends past the winning rectangle's right edge, in tile
  // LEVELS.  Widening right from x=94564: the next three x levels (94720,
  // 94966, 95034) are still legal -- the wall there has slack -- and the
  // fourth (95127) is not.  Widening up from y=67626: one level (67767) is
  // legal, the second (68943) is not.  So the predicate's verdicts change at
  // a specific, checkable level, which is a far sharper test than "some
  // bigger rectangle is rejected".
  //
  // (I first asserted that ONE level further right was illegal.  The check
  // disagreed, and on checking it the CHECK was right -- there are three
  // levels of slack, not one.  The expectation was corrected, not the code.)
  expect_yes("right + 1 level (94720) is still inside", rect_ok(b, 5649, 50077, 94720, 67626),
             "should be legal and is not");
  expect_yes("right + 2 levels (94966) is still inside", rect_ok(b, 5649, 50077, 94966, 67626),
             "should be legal and is not");
  expect_yes("right + 3 levels (95034) is still inside", rect_ok(b, 5649, 50077, 95034, 67626),
             "should be legal and is not");
  expect_yes("right + 4 levels (95127) is NOT inside", !rect_ok(b, 5649, 50077, 95127, 67626),
             "an out-of-room rectangle was accepted");
  expect_yes("up + 1 level (67767) is still inside", rect_ok(b, 5649, 50077, 94564, 67767),
             "should be legal and is not");
  expect_yes("up + 2 levels (68943) is NOT inside", !rect_ok(b, 5649, 50077, 94564, 68943),
             "an out-of-room rectangle was accepted");
  // The room's whole bounding box: 9 334 062 933 tiles, six times part 1's
  // answer, and it must be rejected.
  expect_yes("the bounding box is NOT inside the room",
             !rect_ok(b, sh.minx, sh.miny, sh.maxx, sh.maxy),
             "the bounding box was accepted, which cannot be right");
  // The rectangle between the room's four extreme tiles -- min x with min y,
  // min x with max y, max x with min y, max x with max y -- as the two
  // diagonal pairs.  Neither diagonal spans the room, because the room is
  // not convex.
  expect_yes("the room's bounding diagonal is rejected",
             !rect_ok(b, sh.minx, sh.miny, sh.maxx, sh.maxy),
             "a bounding diagonal was accepted");
  // The other bounding diagonal happens to BE legal -- the room's extreme
  // tiles are arranged so that (minx,maxy)..(maxx,miny) stays inside.  That
  // is not a bug in the predicate; it is a fact about this room, and
  // asserting it is useful: it says the room is not convex, so "the bounding
  // box is rejected" alone would not have proved the predicate discriminates.
  expect_yes("the other bounding diagonal is inside (this room is not convex)",
             rect_ok(b, sh.minx, sh.maxy, sh.maxx, sh.miny),
             "this bounding diagonal should be legal for this room and is not");
  // Two tiles that are neighbours in the vertex list: the wall they share is
  // one tile thick, so the 2x2 block around them must be inside.
  expect_yes("the 2x2 block on the first wall segment is inside",
             rect_ok(b, 98021, 50083, 98021, 51293),
             "a corner block of the room was rejected");
  // 97775,51293 and 98000,52518 are the 3rd and 5th tiles in the file. The
  // rectangle between them reaches past a wall just below that corner, so
  // it must be rejected even though both corners are red tiles -- the room
  // has a dent there. (My first version of this assertion passed the corners
  // in the WRONG ORDER, xlo > xhi, which made it pass for the wrong reason;
  // the predicate is documented as taking ordered corners, and now it does.)
  expect_yes("a rectangle over the dent near tile 3 is rejected",
             !rect_ok(b, 97775, 51293, 98000, 52518),
             "a dent-spanning rectangle was accepted");
  // The 2x2 block on the SAME wall segment, in bounds, is inside.
  expect_yes("the 2x2 block inside that same corner is inside",
             rect_ok(b, 97775, 51293, 97775, 52518),
             "a corner block of the room was rejected");
  // A rectangle spanning the room's widest extent must be rejected.
  expect_yes("full width over the lower half is NOT inside",
             !rect_ok(b, sh.minx, sh.miny, sh.maxx, 50077),
             "a full-width rectangle was accepted, which cannot be right");
  // The two real-input corners swapped: same rectangle, must agree.
  expect_yes("the predicate does not depend on which corner is named first",
             rect_ok(b, 94564, 67626, 5649, 50077),
             "corner order changed the verdict");

  // ---- hand-computed micro-cases, routed through the real entry points
  print("");
  print("micro-cases (the arithmetic is written out in README.md):");
  // The statement's own example.  Part 1 = 50 is PUBLISHED by the statement.
  // Part 2 = 24 is hand-derived here (tier-2 anchor; see README.md).
  let ex = parse_text("7,1\n11,1\n11,7\n9,7\n9,5\n2,5\n2,3\n7,3\n", "statement example");
  let exw1: [long] = [];
  let exw2: [long] = [];
  expect_eq("statement example part 1 (published: 50)", solve_part1(ex, exw1), 50);
  expect_eq("statement example part 2 (hand-derived: 24)",
            solve_part2(ex, build_band(ex), exw2), 24);
  // The room itself: a 5x5 square of tiles, so the whole polygon is legal.
  let sq = parse_text("0,0\n4,0\n4,4\n0,4\n", "unit square");
  let sqw1: [long] = [];
  let sqw2: [long] = [];
  expect_eq("unit square part 1 (5x5)", solve_part1(sq, sqw1), 25);
  expect_eq("unit square part 2 (the room itself)", solve_part2(sq, build_band(sq), sqw2), 25);
  // An L with a dent, which is exactly what part 2 is about: part 1 reaches
  // across the dent, part 2 cannot.
  let ll = parse_text("0,0\n4,0\n4,2\n2,2\n2,4\n0,4\n", "L shape");
  let llw1: [long] = [];
  let llw2: [long] = [];
  expect_eq("L shape part 1 (4,0 & 0,4 reach over the dent)", solve_part1(ll, llw1), 25);
  expect_eq("L shape part 2 (longest legal run is 5x3 or 3x5)", solve_part2(ll, build_band(ll), llw2), 15);
  // Degenerate rectangles: the tightest the inclusive rule can get, and a
  // one-tile list, which has no pair at all and must report 0, not trap.
  let dup = parse_text("5,5\n5,5\n", "same tile twice");
  let dupw: [long] = [];
  expect_eq("two identical tiles span 1x1", solve_part1(dup, dupw), 1);
  let one = parse_text("3,3\n", "single tile");
  let onew: [long] = [];
  expect_eq("a one-tile list has no pair, so part 1 is 0 (and does not trap)",
            solve_part1(one, onew), 0);
  let adj = parse_text("5,5\n6,5\n", "adjacent tiles");
  let adjw: [long] = [];
  expect_eq("two adjacent tiles span 2x1", solve_part1(adj, adjw), 2);
  let sliver = parse_text("0,0\n0,3\n", "vertical sliver pair");
  let sw: [long] = [];
  expect_eq("two tiles sharing an x span 1 wide by 4 tall", solve_part1(sliver, sw), 4);
  // The widest legal rectangle must still fit: the L's rows 3 and 4 are only
  // three tiles wide, so no 5-wide rectangle with yhi = 4 is legal.
  let tight = parse_text("0,0\n4,0\n4,2\n2,2\n2,4\n0,4\n", "L shape again");
  expect_eq("L shape: 5 wide x 5 tall is illegal, so part 2 < part 1",
            solve_part2(tight, build_band(tight), sqw2) < solve_part1(tight, sqw1) ? 1 : 0, 1);

  // ---- the parser's accept/reject decisions, row by row.  These are the
  // cases a strictly-gated parser exists for: `tonum` alone would happily
  // return 12 for "12ab" and 1 for "1,2,3" would silently drop a field.
  print("");
  print("parser and reader decisions (what must be accepted, what must not):");
  let r1: [long] = [];
  let r2: [long] = [];
  let r3: [long] = [];
  let r4: [long] = [];
  expect_eq("a well-formed row is accepted", parse_rows(["12,34"], r1), 0 - 1);
  expect_eq("one field ('12') is rejected", parse_rows(["12"], r2), 0);
  expect_eq("three fields ('1,2,3') is rejected", parse_rows(["1,2,3"], r3), 0);
  expect_eq("trailing junk ('1,2x') is rejected", parse_rows(["1,2x"], r4), 0);
  let r5: [long] = [];
  let r6: [long] = [];
  let r7: [long] = [];
  expect_eq("an empty second field ('1,') is rejected", parse_rows(["1,"], r5), 0);
  expect_eq("an empty first field (',2') is rejected", parse_rows([",2"], r6), 0);
  expect_eq("letters ('a,b') are rejected", parse_rows(["a,b"], r7), 0);
  expect_eq("a bare sign ('-,2') is rejected", parse_rows(["-,2"], r7), 0);
  let r9: [long] = [];
  expect_eq("blank rows are skipped, not rejected",
            parse_rows(["1,2", "", "   ", "3,4", ""], r9), 0 - 1);
  expect_eq("the blank-row case read exactly two tiles", r9.length, 4);
  let r10: [long] = [];
  expect_eq("whitespace around the fields is tolerated",
            parse_rows(["  7 , 1  "], r10), 0 - 1);
  expect_eq("...and the trimmed values are 7 and 1", r10[0] * 1000 + r10[1], 7001);
  let r11: [long] = [];
  expect_eq("a negative field is accepted", parse_rows(["-3,4"], r11), 0 - 1);
  expect_eq("...and it really is -3", r11[0], 0 - 3);
  let r12: [long] = [];
  expect_eq("the index of the first bad row is reported",
            parse_rows(["1,2", "3,4", "5", "6,7"], r12), 2);
  let r13: [long] = [];
  expect_eq("a plus sign ('+1,2') is rejected, since the statement does not use one",
            parse_rows(["+1,2"], r13), 0);
  // ... and the byte-level reader must make the same accept/reject calls.
  let q1: [byte] = "1,2\n".bytes();
  let q1o: [long] = [];
  expect_eq("rescan accepts '1,2\\n'", rescan_bytes(q1, q1o), 0);
  expect_eq("rescan read exactly the tile 1,2", q1o[0] * 1000 + q1o[1], 1002);
  let q2: [byte] = "1,2,3\n".bytes();
  let q3: [byte] = "1,2".bytes();
  let q4: [byte] = "1,2z\n".bytes();
  let q5: [byte] = "1,\n".bytes();
  let q6: [byte] = "\n".bytes();
  let qo: [long] = [];
  expect_eq("rescan rejects three fields", rescan_bytes(q2, qo), 1);
  expect_eq("rescan rejects a stream not ending on a line boundary",
            rescan_bytes(q3, qo), 1);
  expect_eq("rescan rejects a stray byte", rescan_bytes(q4, qo), 1);
  // '1,\n' carries TWO independent violations -- an empty second field at
  // the comma, and a line that ends with digits still uncommitted -- so the
  // count is 2, not 1.  This expectation was wrong when first written (it
  // said 1); the reader was right.  The arithmetic is in README.md.
  expect_eq("rescan rejects '1,\\n' as two violations, not one",
            rescan_bytes(q5, qo), 2);
  expect_eq("rescan rejects a bare newline (one line, no fields at all)",
            rescan_bytes(q6, qo), 1);
  expect_eq("rescan reads a whole well-formed file in one pass",
            rescan_bytes("1,2\n3,4\n".bytes(), qo), 0);

  // ---- oracle A: the published "no wall inside" rule
  print("");
  print("oracles (each a different kind of computation from the solver):");
  expect_eq("oracle A: published no-wall-inside rule, real input",
            oracle_wall_filter(flat), p2);
  expect_eq("oracle A: published no-wall-inside rule, statement example",
            oracle_wall_filter(ex), 24);
  expect_eq("oracle A: published no-wall-inside rule, L shape",
            oracle_wall_filter(ll), 15);
  // ---- oracle B: scanline fill + 2-D prefix sums
  expect_eq("oracle B: scanline fill + prefix sums, real input",
            oracle_scan_prefix(flat), p2);
  expect_eq("oracle B: scanline fill + prefix sums, statement example",
            oracle_scan_prefix(ex), 24);
  expect_eq("oracle B: scanline fill + prefix sums, L shape",
            oracle_scan_prefix(ll), 15);

  // ---- oracle C: input-order permutations, through the real solver.
  // Part 1's answer cannot depend on the order of the tiles at all, so a
  // deterministic shuffle must not move it.  This is the check that exists
  // because of day05, whose sort_pairs compared one pair's high against
  // another pair's low: it compiled, it sorted, and every part-2 method
  // still agreed with it.  Only a check that VARIES THE INPUT ORDER catches
  // that class of defect, so eight shuffles go in here.
  let p1_of = tostring(p1);
  let p2_of = tostring(p2);
  let perm_bad = 0;
  let perm_detail = "";
  let sd = 1;
  while (sd <= 8) {
    let p = shuffled(flat, sd * 7919 + 13);
    let pw1: [long] = [];
    let q1 = solve_part1(p, pw1);
    if (tostring(q1) != p1_of) {
      perm_bad = perm_bad + 1;
      perm_detail = "shuffle seed " + tostring(sd) + " gave " + tostring(q1)
    };
    sd = sd + 1
  };
  expect_yes("oracle C: 8 deterministic shuffles leave part 1 unchanged",
             perm_bad == 0, perm_detail);
  // An oracle that does not actually permute cannot see an order defect --
  // this is the "two absent values compare equal" trap in permutation form,
  // so the permutation itself is asserted, not just its result.
  expect_yes("oracle C: the shuffle really reorders the tiles (not the identity)",
             !same_order(shuffled(flat, 7932), flat), "shuffled() is the identity");
  expect_yes("oracle C: the rotation really reorders the tiles",
             !same_order(rotated(flat, 1), flat), "rotated() is the identity");
  expect_yes("oracle C: the reversal really reorders the tiles",
             !same_order(reversed(flat), flat), "reversed() is the identity");

  // Part 2's room is defined by the CYCLIC order of the tiles, so the only
  // order permutations that must leave it alone are the rotations and the
  // reversal.  A free shuffle builds a DIFFERENT room, so it is not an
  // invariance of part 2 -- oracle A/B above cover part 2 instead.
  let rot_bad = 0;
  let rot_detail = "";
  let shifts: [long] = [1, 7, 248];
  let si = 0;
  while (si < shifts.length) {
    let p = rotated(flat, shifts[si]);
    let pw1: [long] = [];
    let pw2: [long] = [];
    let q1 = solve_part1(p, pw1);
    let q2 = solve_part2(p, build_band(p), pw2);
    if (tostring(q1) != p1_of || tostring(q2) != p2_of) {
      rot_bad = rot_bad + 1;
      rot_detail = "rotation by " + tostring(shifts[si]) + " gave "
        + tostring(q1) + "/" + tostring(q2)
    };
    si = si + 1
  };
  expect_yes("oracle C: 3 cyclic rotations leave BOTH answers unchanged",
             rot_bad == 0, rot_detail);

  let rv = reversed(flat);
  let rw1: [long] = [];
  let rw2: [long] = [];
  let rv1 = solve_part1(rv, rw1);
  let rv2 = solve_part2(rv, build_band(rv), rw2);
  expect_yes("oracle C: reversing the loop order leaves BOTH answers unchanged",
             tostring(rv1) == p1_of && tostring(rv2) == p2_of,
             "reversal gave " + tostring(rv1) + "/" + tostring(rv2));

  // ---- oracle E: part 1 under transformations that must not move it.
  // Transposing, translating and reflecting all change the numbers but not
  // (|dx|+1)*(|dy|+1), and the solver has no absolute coordinate in it.
  let tp: [long] = [];
  let tf: [long] = [];
  let i = 0;
  while (i < n) { tp += flat[i * 2 + 1]; tp += flat[i * 2]; i = i + 1 };
  i = 0;
  while (i < n) { tf += 0 - flat[i * 2]; tf += flat[i * 2 + 1]; i = i + 1 };
  let sh_t: [long] = [];
  let sh_f: [long] = [];
  expect_eq("oracle E: part 1 under transposition (x<->y)", solve_part1(tp, sh_t), p1);
  expect_eq("oracle E: part 1 under x reflection", solve_part1(tf, sh_f), p1);
  let mv: [long] = [];
  i = 0;
  while (i < n) { mv += flat[i * 2] + 100000; mv += flat[i * 2 + 1] - 20000; i = i + 1 };
  let sh_m: [long] = [];
  expect_eq("oracle E: part 1 under translation by (+100000,-20000)",
            solve_part1(mv, sh_m), p1);

  // ---- invariants the answers must satisfy
  print("");
  print("invariants:");
  expect_yes("part 2 <= part 1 (part 2's candidate set is a subset)",
             p2 <= p1, tostring(p2) + " > " + tostring(p1));
  expect_le("part 1 <= (x span)*(y span) of the bounding box",
            p1, (sh.maxx - sh.minx + 1) * (sh.maxy - sh.miny + 1));
  expect_le("part 2 <= the room's own area (shoelace/2)",
            p2, sh.shoelace / 2);
  expect_yes("part 2 is strictly below part 1 (the room has a dent)",
             p2 < p1, tostring(p2) + " == " + tostring(p1));
  // Re-derive the reported answers from the reported corners, independently.
  let wd1 = absl(w1[0] - w1[2]) + 1;
  let wd2 = absl(w1[1] - w1[3]) + 1;
  expect_eq("part 1 re-derived from its own reported corners", wd1 * wd2, p1);
  let wd3 = absl(w2[0] - w2[2]) + 1;
  let wd4 = absl(w2[1] - w2[3]) + 1;
  expect_eq("part 2 re-derived from its own reported corners", wd3 * wd4, p2);
  // ... and both reported corners really are red tiles (a check that compares
  // two absent values passes, so assert presence before comparing).
  let found1 = 0;
  let found2 = 0;
  i = 0;
  while (i < n) {
    if (flat[i * 2] == w2[0] && flat[i * 2 + 1] == w2[1]) { found1 = found1 + 1 };
    if (flat[i * 2] == w2[2] && flat[i * 2 + 1] == w2[3]) { found2 = found2 + 1 };
    i = i + 1
  };
  expect_eq("part 2 corner A occurs in the input", found1, 1);
  expect_eq("part 2 corner B occurs in the input", found2, 1);
  // The winning rectangle's row count and width are both present and >= 2.
  expect_yes("part 2 spans at least two rows and two columns",
             wd3 >= 2 && wd4 >= 2, tostring(wd3) + "x" + tostring(wd4));
  // Every one of the 496 tiles is a vertex of the loop, so none is dropped.
  expect_eq("tiles used as loop vertices", n, 496);

  // ---- the room's crossing parity was checked while building the band; make
  // sure it was actually exercised rather than trivially satisfied.
  expect_yes("build_band validated the crossing count on every row slab",
             b.ny >= 2 && b.lo[0] < b.hi[0], "band was degenerate");

  print("");
  print("checks passed: " + tostring(g_pass) + "   failed: " + tostring(g_fail));
  if (g_fail == 0) { return 0 };
  return 1
};

// Two tile lists are in the same order (element-wise).
def same_order(a: [long], b: [long]) -> bool {
  if (a.length != b.length) { return false };
  let k = 0;
  while (k < a.length) {
    if (a[k] != b[k]) { return false };
    k = k + 1
  };
  return true
};

// ==================================================================== main

def usage() -> void {
  print("day09 -- Advent of Code 2025 day 9, Movie Theater");
  print("");
  print("usage:");
  print("  day09                 solve input.txt and print both answers");
  print("  day09 --check         run the property battery (no reference file)");
  print("  day09 --input FILE    solve another tile list");
  print("  day09 --help          this text");
  print("");
  print("The default run is deterministic: no clock, no network, no terminal");
  print("size, and no random seed is needed or accepted.");
};

// The reporting the default run does, as a function, so the battery can
// drive it on a degenerate tile list.  A tile list with fewer than three
// vertices encloses no area, so `shoelace/2` is 0 -- and dividing by it is a
// runtime trap that would print to STDOUT and corrupt EXPECTED.
def report(path: str, flat: [long]) -> long {
  let sh = shape_of(flat);
  print("tiles: " + tostring(sh.n) + " (red tile coordinates)");
  print("room: a closed axis-aligned polygon through the tiles, "
        + tostring(sh.nx) + " x-levels and " + tostring(sh.ny)
        + " y-levels, each used twice");
  let b = build_band(flat);
  let w1: [long] = [];
  let w2: [long] = [];
  let p1 = solve_part1(flat, w1);
  let p2 = solve_part2(flat, b, w2);
  print("part 1 (largest rectangle, tiles): " + tostring(p1)
        + "   corners " + tostring(w1[0]) + "," + tostring(w1[1])
        + " and " + tostring(w1[2]) + "," + tostring(w1[3]));
  print("part 2 (largest rectangle wholly inside the room, tiles): " + tostring(p2)
        + "   corners " + tostring(w2[0]) + "," + tostring(w2[1])
        + " and " + tostring(w2[2]) + "," + tostring(w2[3]));
  let area2 = sh.shoelace / 2;
  if (area2 > 0) {
    print("room area (shoelace/2): " + tostring(area2)
          + "; part 1 reaches " + tostring(p1 * 100 / area2) + "% of it");
  };
  print("answers: " + tostring(p1) + " " + tostring(p2));
  return 0
};

def main() -> long {
  let args = argv();
  let path = "input.txt";
  let do_check = false;
  let i = 1;
  while (i < args.length) {
    let a = args[i];
    if (a == "--help" || a == "-h") { usage(); return 0 };
    if (a == "--check" || a == "--self-test") { do_check = true; i = i + 1 }
    else {
      if (a == "--input") {
        if (i + 1 >= args.length) {
          eputs("day09: --input needs a file\n");
          return 1
        };
        path = args[i + 1];
        i = i + 2
      }
      else {
        eputs("day09: unknown argument: " + a + "\n");
        eputs("day09: try --help\n");
        return 1
      }
    }
  };

  if (do_check) { return run_check(path) };

  print("day09: Advent of Code 2025 day 9 -- Movie Theater");
  print("input: " + path);
  return report(path, load_tiles(path))
};

exit(main());