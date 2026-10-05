// day08.y -- Advent of Code 2025, day 8 ("Playground"), in Y.
//
// A list of junction boxes hangs in 3D space, one "X,Y,Z" per line.  Consider
// every PAIR of boxes, order the pairs by straight-line distance, and wire
// them up shortest first; wiring a pair whose boxes are already in one circuit
// does nothing.  A circuit is exactly a connected component of the graph of
// wired pairs, so both parts are a union-find over the pairs in ascending
// distance order:
//
//   part 1  wire the 1000 shortest pairs, then multiply the sizes of the three
//           largest circuits                       (the statement's own words)
//   part 2  keep wiring until every box is in ONE circuit; that connection is
//           the last pair -- multiply those two boxes' X coordinates
//           (NOT from AoC: part 2 is login-gated.  README.md names the two
//            write-ups that define it and the example value they publish.)
//
// Two hand-written orderings of the pair list live here because the language
// has no sort: radix_order (LSD radix, what the answers come from) and
// heap_order (a binary min-heap, used by --check to cross-check it).
//
// build: ../../../refs/ycc.ref day08.y -o day08
// run:   ./day08            (input.txt -> both answers)
//        ./day08 --check    (property battery; no reference file involved)
//        ./day08 --help
import fs;
// std's assertion helper: it replaced this file's own `ck`/`eq`, which are gone
// -- see "--check scaffolding" below.
import test;

// ── constants ───────────────────────────────────────────────────────────────

const MAXN = 1024;         // boxes the fixed scratch arrays hold (statement: 1000)
const MAXPAIRS = 524288;   // MAXN*(MAXN-1)/2 = 523776, the widest pair list
const EDGES = 524288;    // pairs pre-decoded for the --check flood fill
const PART1_PAIRS = 1000;  // the statement's own connection count
const RADIX = 256;         // buckets per radix pass
const RADIX_BITS = 8;
const PASSES = 6;          // 6 * 8 = 48 bits >= the 35 a squared distance needs
const CH_ZERO = 48;        // '0'
const CH_NINE = 57;        // '9'
const CH_COMMA = 44;       // ','
const CH_MINUS = 45;       // '-'
const MAX_DIGITS = 18;     // one more digit and a coordinate would overflow

// ── module state ────────────────────────────────────────────────────────────
// Every buffer below is a fixed literal-sized array allocated ONCE at module
// level: the heap is an arena, so a literal inside a loop would cost its bytes
// on every turn and the hot path must allocate nothing at all.

let bx: [long] = [0; 1024];         // box coordinates, one array per axis
let by: [long] = [0; 1024];
let bz: [long] = [0; 1024];
let boxes_n: long = 0;

let pair_key: [long] = [0; 524288]; // key[t] = SQUARED distance of pair t
let ord_radix: [long] = [0; 524288];
let ord_heap: [long] = [0; 524288];
let radix_tmp: [long] = [0; 524288];
let heap_buf: [long] = [0; 524288];

let uf_parent: [long] = [0; 1024];  // union-find: parent[] and the size at
let uf_size: [long] = [0; 1024];     // each root; uf_circuits counts the sets
let uf_circuits: long = 0;

let walk_comp: [long] = [0; 1024];  // --check's independent flood fill
let walk_queue: [long] = [0; 1024];
let edge_a: [long] = [0; 524288];   // its accepted pairs, pre-decoded
let edge_b: [long] = [0; 524288];

let sz_buf: [long] = [0; 1024];     // circuit sizes, ascending, in sz_buf[0..sz_n)
let sz_n: long = 0;
// The same sizes as they stood at part 1's cut, kept so a later flood fill
// (which reuses sz_buf) can still be compared against union-find.
let cut_buf: [long] = [0; 1024];
let cut_n: long = 0;

let bucket: [long] = [0; 256];
let dec_a: long = 0;                // where decode_pair leaves a pair's boxes
let dec_b: long = 0;

let parse_err: str = "";
let last_parse_ok: bool = false;

// --check bookkeeping.  `first_failure` is the NAME of the first assertion that
// failed, which std's counter does not keep; the tally itself is std's
// (test.checks() / test.failures()) -- the two globals this file used to carry
// for it are gone with the local assertion helper.
let first_failure: str = "";

// What one solve of one input produced.  Every field is a long, and the record
// is used by the report and by the assertions, so it gets an alias.
type Solved = {
    n: long, m: long, k_used: long,
    product: long, c1: long, c2: long, c3: long,
    circuits: long, merged: long, sum_sizes: long,
    tie_at_cut: long, key_at_cut: long, key_after_cut: long,
    last_pair: long, last_a: long, last_b: long,
    last_xa: long, last_xb: long, part2: long, steps_to_one: long
};

// The boxes, as the solver and the checks both read them.
type Boxes = { n: long, xs: [long], ys: [long], zs: [long] };

// ── input ───────────────────────────────────────────────────────────────────

// The commas in `s`.  Counting bytes instead of trusting split() is the whole
// point: split() drops exactly ONE trailing empty field, so a line written
// "162,817,812," would split into three fields and look like a well-formed
// X,Y,Z line when it is a four-field one with a missing coordinate.
def comma_count(s: str) -> long {
    let c = 0;
    let i = 0;
    while (i < s.length) {
        if (s[i] == CH_COMMA) { c = c + 1 };
        i = i + 1;
    };
    c
}

// A coordinate field as a number, or none when it is not a plain decimal
// integer.  The statement guarantees X,Y,Z, so none only happens on input
// that is not this puzzle's; it is reported with its line, never guessed at.
def coord_value(f: str) -> long? {
    if (f.length == 0 || f.length > MAX_DIGITS + 1) {
        none
    } else {
        let i = 0;
        let neg = false;
        if (f[0] == CH_MINUS) { neg = true; i = 1 };
        if (i >= f.length) {
            none
        } else {
            let v = 0;
            let ok = true;
            while (i < f.length && ok) {
                let c = f[i];
                if (c >= CH_ZERO && c <= CH_NINE) {
                    v = v * 10 + (c - CH_ZERO);
                    i = i + 1;
                } else { ok = false };
            };
            if (!ok) { none } else if (neg) { some(0 - v) } else { some(v) }
        }
    }
}

// Parse every line into the module-level bx/by/bz.  True when all lines were
// well formed; otherwise parse_err names the 1-based line and the reason.
// A blank line, a line without exactly two commas, or a field that is not an
// integer is an ERROR: this puzzle's input has no other reading, so guessing
// would be worse than refusing.
def parse_boxes(lines: [str]) -> bool {
    let n = 0;
    parse_err = "";
    let t = 0;
    let ok = true;
    while (t < lines.length && ok) {
        // A CRLF file leaves a CR on the line; it is not part of a coordinate.
        let s = lines[t].trim_end();
        let f = s.split(",");
        let why = "";
        if (s.length == 0) {
            why = "empty line";
        } else if (comma_count(s) != 2 || f.length != 3) {
            // Both tests must pass and neither is redundant.  A trailing comma
            // gives two commas but only three split fields, because split()
            // drops exactly one trailing empty field -- and "1,,3" gives three
            // split fields with an empty middle one, which coord_value below
            // refuses.  Either test alone lets a malformed line through.
            why = "expected X,Y,Z: " + tostring(comma_count(s)) + " commas, " + tostring(f.length) + " fields";
        } else if (n >= MAXN) {
            why = "more than " + tostring(MAXN) + " junction boxes";
        } else {
            let a = coord_value(f[0]);
            let b = coord_value(f[1]);
            let c = coord_value(f[2]);
            if (a == none || b == none || c == none) {
                why = "not three integers";
            } else {
                bx[n] = a!;
                by[n] = b!;
                bz[n] = c!;
                n = n + 1;
            };
        };
        if (why != "") {
            parse_err = "line " + tostring(t + 1) + ": " + why;
            ok = false;
        };
        t = t + 1;
    };
    boxes_n = n;
    if (ok && n < 2) {
        parse_err = "only " + tostring(n) + " junction box(es): no pair to connect";
        ok = false;
    };
    ok
}

def current_boxes() -> Boxes { { n: boxes_n, xs: bx, ys: by, zs: bz } }

// ── the pair list ───────────────────────────────────────────────────────────

def pair_total(n: long) -> long { n * (n - 1) / 2 }

// SQUARED distance.  Squared, not square-rooted: the language has no sqrt and
// no math at all, and squaring a non-negative length is strictly monotone, so
// the ORDER of the pairs is identical and no pair can tie here that would not
// tie unsquared.
def pair_key_at(b: Boxes, a: long, c: long) -> long {
    let dx = b.xs[a] - b.xs[c];
    let dy = b.ys[a] - b.ys[c];
    let dz = b.zs[a] - b.zs[c];
    dx * dx + dy * dy + dz * dz
}

// Fill pair_key[0..m) in enumeration order -- row i holds box i against every
// box j > i -- and return m, the number of pairs.
def build_keys(b: Boxes) -> long {
    let t = 0;
    let i = 0;
    while (i < b.n) {
        let j = i + 1;
        while (j < b.n) {
            pair_key[t] = pair_key_at(b, i, j);
            t = t + 1;
            j = j + 1;
        };
        i = i + 1;
    };
    t
}

// The boxes that pair index `p` names, left in dec_a / dec_b.  A pair index
// counts rows of (n-1-i) pairs for i = 0, 1, 2, ..., so inverting it means
// walking the rows: O(n) per call, and only a few thousand calls happen.
def decode_pair(p: long, n: long) -> void {
    let i = 0;
    let off = 0;
    let done = false;
    while (!done && i < n - 1) {
        let row = n - i - 1;
        if (p < off + row) {
            dec_a = i;
            dec_b = i + 1 + (p - off);
            done = true;
        } else {
            off = off + row;
            i = i + 1;
        };
    }
}

// Order the pair indices by pair_key, least significant byte first: six stable
// 8-bit passes is 48 bits, comfortably more than the 35 bits a squared 3D
// distance needs.  Six is even, so the result lands back in ord_radix (Y
// arrays are references, so that is an in-place sort of the caller's array).
// Stable means pairs of equal distance keep pair order, so the answer never
// depends on how a tie was broken -- and --check asserts the cut is clean.
def radix_order(m: long) -> void {
    let t = 0;
    while (t < m) { ord_radix[t] = t; t = t + 1 };
    let p = 0;
    while (p < PASSES) {
        let shift = p * RADIX_BITS;
        let c = 0;
        while (c < RADIX) { bucket[c] = 0; c = c + 1 };
        t = 0;
        while (t < m) {
            let v = (pair_key[ord_radix[t]] >> shift) & 255;
            bucket[v] = bucket[v] + 1;
            t = t + 1;
        };
        let sum = 0;
        c = 0;
        while (c < RADIX) {
            sum = sum + bucket[c];
            bucket[c] = sum;
            c = c + 1;
        };
        // Backwards, so equal keys keep their relative order.
        t = m - 1;
        while (t >= 0) {
            let v = (pair_key[ord_radix[t]] >> shift) & 255;
            bucket[v] = bucket[v] - 1;
            radix_tmp[bucket[v]] = ord_radix[t];
            t = t - 1
        };
        t = 0;
        while (t < m) { ord_radix[t] = radix_tmp[t]; t = t + 1 };
        p = p + 1
    }
}

// Move heap slot `root` down until its subtree obeys the heap property.
def sift_down(root: long, size: long) -> void {
    let at = root;
    let done = false;
    while (!done) {
        let l = at * 2 + 1;
        if (l >= size) {
            done = true;
        } else {
            let small = l;
            let r = l + 1;
            if (r < size && pair_key[heap_buf[r]] < pair_key[heap_buf[l]]) { small = r };
            if (pair_key[heap_buf[at]] <= pair_key[heap_buf[small]]) {
                done = true;
            } else {
                let tmp = heap_buf[at];
                heap_buf[at] = heap_buf[small];
                heap_buf[small] = tmp;
                at = small;
            }
        }
    }
}

// The same ordering, by a completely different algorithm: a binary min-heap
// over all m keys, popped k times.  --check runs both orderings through solve
// and compares the keys AND the answers, so a defect in radix_order cannot hide
// behind the heap agreeing with it by accident.  Returns how many were popped.
def heap_order(m: long, k: long) -> long {
    let t = 0;
    while (t < m) { heap_buf[t] = t; t = t + 1 };
    let i = m / 2;
    while (i > 0) {
        i = i - 1;
        sift_down(i, m)
    };
    let popped = 0;
    while (popped < k && popped < m) {
        ord_heap[popped] = heap_buf[0];
        heap_buf[0] = heap_buf[m - popped - 1];
        let sz = m - popped - 1;
        if (sz > 0) { sift_down(0, sz) };
        popped = popped + 1
    };
    popped
}

// ── circuits ────────────────────────────────────────────────────────────────

def uf_reset(n: long) -> void {
    let i = 0;
    uf_circuits = n;
    while (i < n) {
        uf_parent[i] = i;
        uf_size[i] = 1;
        i = i + 1
    }
}

def uf_find(a: long) -> long {
    let r = a;
    while (uf_parent[r] != r) { r = uf_parent[r] };
    // Path compression, so a long chain does not make later finds slow.
    let c = a;
    while (uf_parent[c] != c) {
        let nxt = uf_parent[c];
        uf_parent[c] = r;
        c = nxt
    };
    r
}

// Join two circuits.  1 when they were different circuits and one merge
// happened (and so the circuit count fell by one), 0 when the pair was
// already wired together -- which the statement says happens, and does nothing.
def uf_union(a: long, b: long) -> long {
    let ra = uf_find(a);
    let rb = uf_find(b);
    let merged = 0;
    if (ra != rb) {
        // Union by size, so the forest stays shallow.
        if (uf_size[ra] < uf_size[rb]) {
            let t = ra;
            ra = rb;
            rb = t
        };
        uf_parent[rb] = ra;
        uf_size[ra] = uf_size[ra] + uf_size[rb];
        uf_circuits = uf_circuits - 1;
        merged = 1;
    };
    merged
}

// Insertion sort of xs[0..n) ascending: the language has no sort, and the
// circuit sizes are at most n of them, so the quadratic version is the honest
// one.  (The pair list is too big for it -- that is what radix_order is for.)
def sort_prefix(xs: [long], n: long) -> void {
    let i = 1;
    while (i < n) {
        let v = xs[i];
        let j = i - 1;
        while (j >= 0 && xs[j] > v) {
            xs[j + 1] = xs[j];
            j = j - 1
        };
        xs[j + 1] = v;
        i = i + 1
    }
}

// Every circuit's size, ascending, left in sz_buf[0..sz_n); returns how many.
// Fewer than three circuits pads with 1, the usual reading of "the three
// largest" when there are not three.
def circuit_sizes(n: long) -> long {
    sz_n = 0;
    let i = 0;
    while (i < n) {
        if (uf_parent[i] == i) {
            sz_buf[sz_n] = uf_size[i];
            sz_n = sz_n + 1
        };
        i = i + 1
    };
    sort_prefix(sz_buf, sz_n);
    sz_n
}

// Wire the pairs in `order` -- any permutation of 0..m-1 that is sorted by
// nondecreasing pair_key -- and read both answers off the way past.  Part 1 is
// the state after the k_used-th connection; part 2 is the connection that first
// leaves a single circuit, and its two boxes' X coordinates multiplied.
def solve(b: Boxes, order: [long], k: long) -> Solved {
    let n = b.n;
    let m = pair_total(n);
    let kk = k;
    if (kk > m) { kk = m };
    if (kk < 0) { kk = 0 };
    uf_reset(n);
    let t = 0;
    let merged = 0;
    let product = 1;
    let c1 = 1;
    let c2 = 1;
    let c3 = 1;
    let cks = n;
    let sum_sizes = n;
    let tie = 0;
    let key_at = 0 - 1;
    let key_after = 0;
    let last_pair = 0 - 1;
    let la = 0 - 1;
    let lb = 0 - 1;
    let xa = 0;
    let xb = 0;
    let part2 = 0;
    let took = false;
    while (t < m) {
        let p = order[t];
        // A malformed order must not become an out-of-bounds trap below.
        if (p < 0 || p >= m) { p = 0 };
        decode_pair(p, n);
        let a = dec_a;
        let c = dec_b;
        // Every pair gets wired, not just the first kk: part 2 is the same
        // wiring carried on until one circuit is left.  `merged` only counts
        // the pairs part 1's cut is allowed to have consumed.
        let did = uf_union(a, c);
        if (t < kk) { merged = merged + did };
        if (!took && t == kk - 1) {
            cks = circuit_sizes(n);
            cut_n = cks;
            let keep = 0;
            while (keep < cks) { cut_buf[keep] = sz_buf[keep]; keep = keep + 1 };
            sum_sizes = 0;
            let q = 0;
            while (q < sz_n) { sum_sizes = sum_sizes + sz_buf[q]; q = q + 1 };
            if (sz_n >= 1) { c1 = sz_buf[sz_n - 1] };
            if (sz_n >= 2) { c2 = sz_buf[sz_n - 2] };
            if (sz_n >= 3) { c3 = sz_buf[sz_n - 3] };
            product = c1 * c2 * c3;
            key_at = pair_key[p];
            if (t + 1 < m) {
                key_after = pair_key[order[t + 1]];
                if (key_after == key_at) { tie = 1 }
            };
            took = true
        };
        if (last_pair < 0 && n > 1 && uf_circuits == 1) {
            last_pair = t;
            la = a;
            lb = c;
            xa = b.xs[a];
            xb = b.xs[c];
            part2 = xa * xb
        };
        t = t + 1
    };
    // k_used == 0: nothing was wired, so n circuits of one box each.
    if (!took) {
        cks = n;
        cut_n = n;
        let keep0 = 0;
        while (keep0 < n) { cut_buf[keep0] = 1; keep0 = keep0 + 1 };
        sum_sizes = n;
        c1 = 1;
        c2 = 1;
        c3 = 1;
        product = 1;
        key_at = 0 - 1;
        key_after = 0
    };
    { n: n, m: m, k_used: kk, product: product, c1: c1, c2: c2, c3: c3,
      circuits: cks, merged: merged, sum_sizes: sum_sizes, tie_at_cut: tie,
      key_at_cut: key_at, key_after_cut: key_after, last_pair: last_pair,
      last_a: la, last_b: lb, last_xa: xa, last_xb: xb, part2: part2,
      steps_to_one: last_pair + 1 }
}

// ── the independent method, for --check only ────────────────────────────────

// The component sizes of the graph whose edges are the first `k` pairs in
// `order`, found by WALKING those edges instead of by union-find: every box
// starts unlabelled and each unlabelled box seeds a flood fill.  Sizes end up
// ascending in sz_buf[0..sz_n) and each box's component id in walk_comp, so a
// caller can also ask which component a box is in.  Returns the component
// count, or -1 when k is past what the pre-decoded edge buffers hold.
//
// This shares decode_pair with the solver -- the hand-written expected pair
// order asserted in t_pairs kills a defect there -- but nothing else: no
// uf_parent, no uf_size, no radix.  O(n*k), hopeless for the real solve, which
// is the point.
def walk_components(n: long, order: [long], k: long) -> long {
    if (k > EDGES) { 0 - 1 } else {
        let t = 0;
        while (t < k) {
            let p = order[t];
            if (p < 0) { p = 0 };
            decode_pair(p, n);
            edge_a[t] = dec_a;
            edge_b[t] = dec_b;
            t = t + 1
        };
        let i = 0;
        while (i < n) { walk_comp[i] = 0 - 1; i = i + 1 };
        sz_n = 0;
        let comps = 0;
        let seed = 0;
        while (seed < n) {
            if (walk_comp[seed] < 0) {
                let head = 0;
                let tail = 0;
                let count = 0;
                walk_queue[tail] = seed;
                tail = tail + 1;
                walk_comp[seed] = comps;
                let growing = true;
                while (growing) {
                    if (head == tail) {
                        growing = false;
                    } else {
                        let u = walk_queue[head];
                        head = head + 1;
                        count = count + 1;
                        let e = 0;
                        while (e < k) {
                            let other = 0 - 1;
                            if (edge_a[e] == u) {
                                other = edge_b[e];
                            } else if (edge_b[e] == u) {
                                other = edge_a[e]
                            };
                            if (other >= 0 && walk_comp[other] < 0) {
                                walk_comp[other] = comps;
                                walk_queue[tail] = other;
                                tail = tail + 1
                            };
                            e = e + 1
                        }
                    }
                };
                sz_buf[sz_n] = count;
                sz_n = sz_n + 1;
                comps = comps + 1
            };
            seed = seed + 1
        };
        sort_prefix(sz_buf, sz_n);
        comps
    }
}

// ── --check scaffolding ─────────────────────────────────────────────────────
//
// THE ASSERTION HELPER IS STD'S.  This file used to define its own
// `ck(name, ok, detail)` and `eq(name, got, want)` and to keep two counters
// beside them; all four are gone.  Every call below now reads
// `test.ck(name, ok, detail)` or `test.ck_eq(name, got, want)`
// (src/y/std/test.y), the tallies come from `test.checks()` and
// `test.failures()`, and the only thing this file still owns is the NAME of THE
// FIRST FAILURE -- std reports a count, not which one, and the FAIL line at the
// bottom of run_check() says which.
//
// The argument order did not move: the local `ck` already read (name, ok,
// detail), which is the order std reads, so no call site had to be reordered.
// The ARGUMENT that did move is `eq`: the local one built its own detail string
// out of got and want, and std's ck_eq builds that string itself.
//
// The two functions below are NOT assertions any more: they print nothing and
// count nothing.  They are the two-line remainder of this file's old helper --
// the one thing std does not keep, which is the NAME of the first failure --
// and they exist so that seventy-odd call sites did not each have to grow it.
//
// What changed in the output: a passing assertion is printed as "  ok    name"
// with the detail on a second line under it (std always shows the detail, on
// both outcomes -- a FAIL states what was measured and what was wanted), where
// the local helper printed the name alone on a pass.  `EXPECTED` does not move:
// --check output is not a golden here.
def ck(name: str, ok: bool, detail: str) -> bool {
    let passed = test.ck(name, ok, detail);
    if (!passed && first_failure == "") { first_failure = name };
    passed
}

def eq(name: str, got: long, want: long) -> bool {
    let passed = test.ck_eq(name, got, want);
    if (!passed && first_failure == "") { first_failure = name };
    passed
}

// refusal(what) -> str -- the detail line for a check of the shape "this input
// must NOT parse".
//
// It exists because std's `ck` prints the detail on BOTH outcomes, and eight of
// this file's details were phrased as the failure they described ("an empty
// file parsed").  Under an `ok    empty file is refused` line that reads as a
// contradiction.  With this, the line says what happened either way, and when
// the parser took something it should not have it names what got in.
//
// It reads `parse_err` rather than the return value on purpose: parse_boxes
// leaves parse_err describing its LAST attempt, so this is correct whichever
// order the two arguments of the ck() call are evaluated in.
def refusal(what: str) -> str {
    if (parse_err == "") { "PARSED ANYWAY: " + what } else { "refused, as required: " + parse_err }
}

// Parse a literal input and solve it the way the binary solves a file, so a
// defect in solve() is injected into the check rather than bypassed.
def solve_lines(lines: [str], k: long) -> Solved {
    last_parse_ok = parse_boxes(lines);
    let b = current_boxes();
    let m = build_keys(b);
    radix_order(m);
    solve(b, ord_radix, k)
}

def print_usage() -> void {
    print("day08 -- Advent of Code 2025, day 8 (Playground), in Y");
    print("");
    print("  ./day08 [--input FILE] [--pairs K]   both answers (default: input.txt)");
    print("  ./day08 --check                      property battery, no reference file");
    print("  ./day08 --help                       this");
    print("");
    print("Junction boxes come one X,Y,Z per line.  Every pair is ordered by");
    print("straight-line distance and wired up shortest first; a pair already in");
    print("one circuit does nothing.");
    print("  part 1  the K shortest connections, product of the three largest circuits");
    print("  part 2  keep wiring until every box is in one circuit, then the X");
    print("          coordinates of that last pair multiplied");
}

// ── the report ──────────────────────────────────────────────────────────────

def report(src: str, k: long) -> long {
    let b = current_boxes();
    let m = build_keys(b);
    radix_order(m);
    let s = solve(b, ord_radix, k);
    print("day08: " + src + ": " + tostring(s.n) + " junction boxes, " + tostring(s.m) + " candidate pairs");
    print("");
    print("part 1: the " + tostring(s.k_used) + " shortest connections");
    print("  circuits left " + tostring(s.circuits) + ", of which " + tostring(s.merged) + " connections joined two circuits");
    print("  three largest " + tostring(s.c1) + ", " + tostring(s.c2) + ", " + tostring(s.c3));
    print("  answer 1 = " + tostring(s.product));
    print("");
    print("part 2: wiring on until every box is in one circuit");
    if (s.last_pair < 0) {
        print("  no connection completed a single circuit");
        print("  answer 2 = 0");
    } else {
        print("  finished by connection " + tostring(s.steps_to_one) + " of the ordered pairs");
        print("  boxes " + tostring(s.last_a) + " and " + tostring(s.last_b) + ", X = " + tostring(s.last_xa) + " and " + tostring(s.last_xb));
        print("  answer 2 = " + tostring(s.part2));
    };
    print("");
    if (s.k_used == 0) {
        print("note: no connections were made (k = 0)");
    } else if (s.tie_at_cut == 1) {
        print("note: the part 1 cut falls inside a group of equal distances");
    } else {
        print("note: the part 1 cut is unambiguous (" + tostring(s.key_at_cut) + " < " + tostring(s.key_after_cut) + ")");
    };
    0
}

// ── the property battery ────────────────────────────────────────────────────

// The statement's own example (its 20 listed positions) and the answers the
// statement publishes for it: after the ten shortest connections there are 11
// circuits of sizes 5, 4, 2, 2 and seven 1s, and the three largest multiply to
// 40.  Both facts are in the statement, so this is an external anchor.
let EX_LINES: [str] = [
    "162,817,812", "57,618,57", "906,360,560", "592,479,940", "352,342,300",
    "466,668,158", "542,29,236", "431,825,988", "739,650,466", "52,470,668",
    "216,146,977", "819,987,18", "117,168,530", "805,96,715", "346,949,466",
    "970,615,88", "941,993,340", "862,61,35", "984,92,344", "425,690,689"
];

// Boxes on a line, so every distance is an integer and hand-checkable.  See
// README.md for the full hand derivation.
let MICRO_LINES: [str] = ["0,0,0", "3,0,0", "1,0,0", "6,0,0", "10,0,0"];

// The pair order worked out by hand for MICRO_LINES, as pair indices in
// enumeration order: 1:(0,2) 4:(1,2) 0:(0,1) 5:(1,3) 9:(3,4) 7:(2,3) 2:(0,3)
// 6:(1,4) 8:(2,4) 3:(0,4).
let MICRO_ORDER: [long] = [1, 4, 0, 5, 9, 7, 2, 6, 8, 3];
// ... and the same ten as the box pairs they name.
let MICRO_PAIRS: [long] = [0, 2, 1, 2, 0, 1, 1, 3, 3, 4, 2, 3, 0, 3, 1, 4, 2, 4, 0, 4];

def t_input() -> void {
    let lines: [str]? = fs.read_lines("input.txt");
    ck("input.txt reads", lines != none,
       if (lines == none) { "fs.read_lines returned none" } else { tostring(lines!.length) + " lines read" });
    if (lines == none) { return };
    let ls = lines!;
    eq("input.txt line count", ls.length, 1000);
    // The dispatch note says "number pairs"; the file is three fields a line,
    // so check every line rather than trusting either.
    let bad = 0;
    let i = 0;
    while (i < ls.length) {
        let s = ls[i].trim_end();
        if (comma_count(s) != 2 || s.split(",").length != 3) { bad = bad + 1 };
        i = i + 1
    };
    eq("input.txt lines that are not X,Y,Z", bad, 0);
    ck("input.txt parses", parse_boxes(ls), parse_err);
    eq("input.txt box count", boxes_n, 1000);
    let b = current_boxes();
    let coord_sum = 0;
    let j = 0;
    while (j < boxes_n) {
        if (b.xs[j] < 0 || b.ys[j] < 0 || b.zs[j] < 0) { coord_sum = coord_sum + 1 };
        j = j + 1
    };
    eq("input.txt negative coordinates", coord_sum, 0);
    eq("input.txt pairs", pair_total(boxes_n), 499500);
}

def t_micro_pairs() -> void {
    // The hand-computed order of the ten pairs, both as pair indices and as
    // the boxes they name.  Together these kill a defect in build_keys, in
    // radix_order, and in decode_pair.
    last_parse_ok = parse_boxes(MICRO_LINES);
    ck("micro input parses", last_parse_ok, parse_err);
    let m = build_keys(current_boxes());
    eq("micro pair count", m, 10);
    radix_order(m);
    let bad = 0;
    let i = 0;
    while (i < 10) {
        if (ord_radix[i] != MICRO_ORDER[i]) { bad = bad + 1 };
        i = i + 1
    };
    eq("micro pair order by index (hand-derived)", bad, 0);
    let badp = 0;
    let q = 0;
    while (q < 10) {
        decode_pair(ord_radix[q], 5);
        if (dec_a != MICRO_PAIRS[q * 2] || dec_b != MICRO_PAIRS[q * 2 + 1]) { badp = badp + 1 };
        q = q + 1
    };
    eq("micro pair order by box pair (hand-derived)", badp, 0);
    // Keys nondecreasing along the order, and the keys are the distances.
    let mono = 1;
    let kk = 0;
    let prev = 0 - 1;
    while (kk < 10) {
        let key = pair_key[ord_radix[kk]];
        if (key < prev) { mono = 0 };
        prev = key;
        kk = kk + 1
    };
    ck("micro keys nondecreasing along the order", mono == 1,
       if (mono == 1) { "10 keys in order" } else { "a key went backwards" });
}

def t_micro_answers() -> void {
    // Hand-derived in README.md: after the four shortest connections the
    // circuits are {0,1,2,3} and {4}, so 4*1*1 = 4; the connection that
    // finishes the single circuit is (3,4) with X 6 and 10, so 60.
    let s = solve_lines(MICRO_LINES, 4);
    ck("micro parses", last_parse_ok, parse_err);
    eq("micro part 1 product", s.product, 4);
    eq("micro part 1 three largest", s.c1 * 10000 + s.c2 * 100 + s.c3, 40101);
    eq("micro part 1 circuits left", s.circuits, 2);
    eq("micro part 1 merges", s.merged, 3);
    eq("micro part 1 sizes sum to n", s.sum_sizes, 5);
    eq("micro part 2 answer", s.part2, 60);
    eq("micro part 2 pair index", s.last_pair, 4);
    eq("micro part 2 X values", s.last_xa * 1000 + s.last_xb, 6010);
    eq("micro part 2 examined", s.steps_to_one, 5);
    // k = 0: nothing wired, n circuits of one box, and no trap.
    let z = solve_lines(MICRO_LINES, 0);
    eq("micro k=0 product", z.product, 1);
    eq("micro k=0 circuits", z.circuits, 5);
    eq("micro k=0 sizes sum", z.sum_sizes, 5);
    // k past the end clamps to every pair, which is one circuit of five.
    let all = solve_lines(MICRO_LINES, 999);
    eq("micro k>m clamps to all pairs", all.k_used, 10);
    eq("micro all-pairs product", all.product, 5);
    eq("micro all-pairs part 2 unchanged", all.part2, 60);
    // Two boxes: one pair, one circuit, and the third and second largest pad
    // with 1.  X of the pair is 0*4, so part 2 is legitimately 0.
    let two = solve_lines(["0,0,0", "4,5,6"], 1);
    eq("two boxes product", two.product, 2);
    eq("two boxes circuits", two.circuits, 1);
    eq("two boxes part 2", two.part2, 0);
    // One box: no pair at all, so no final connection and no trap.
    let one = solve_lines(["7,8,9"], 1);
    eq("one box product", one.product, 1);
    eq("one box pairs", one.m, 0);
    eq("one box part 2", one.part2, 0);
    eq("one box final connection", one.last_pair, 0 - 1);
}

def t_edge_cases() -> void {
    // Two boxes at the same point: a distance of 0, and a tie straddling the
    // part 1 cut.  A(5,5,5) B(5,5,5) C(10,5,5): pairs (A,B)=0, (A,C)=(B,C)=25.
    let dup: [str] = ["5,5,5", "5,5,5", "10,5,5"];
    let one = solve_lines(dup, 1);
    eq("duplicate points: k=1 product", one.product, 2);
    eq("duplicate points: k=1 cut is clean", one.tie_at_cut, 0);
    let two = solve_lines(dup, 2);
    eq("duplicate points: k=2 product", two.product, 3);
    eq("duplicate points: k=2 cut is tied", two.tie_at_cut, 1);
    eq("duplicate points: part 2", two.part2, 50);
    let three = solve_lines(dup, 3);
    eq("duplicate points: k=3 product", three.product, 3);
    // A single line, and one with a trailing comma: the trailing comma must be
    // REJECTED, because split() would have quietly dropped the empty field and
    // made "1,2,3," look like a valid three-field line.
    ck("one line is refused", !parse_boxes(["1,2,3"]), refusal("a lone line"));
    ck("trailing comma is refused", !parse_boxes(["1,2,3", "4,5,6,"]), refusal("a trailing comma"));
    ck("two fields is refused", !parse_boxes(["1,2,3", "4,5"]), refusal("a two-field line"));
    ck("four fields is refused", !parse_boxes(["1,2,3", "4,5,6,7"]), refusal("a four-field line"));
    ck("blank line is refused", !parse_boxes(["1,2,3", "", "4,5,6"]), refusal("a blank line"));
    ck("words are refused", !parse_boxes(["1,2,3", "4,five,6"]), refusal("a word"));
    ck("a lone minus is refused", !parse_boxes(["1,2,3", "-,-,4"]), refusal("a bare '-'"));
    ck("empty file is refused", !parse_boxes([]), refusal("an empty file"));
    // CRLF input is accepted: the CR is not part of a coordinate.
    ck("CRLF line is accepted", parse_boxes(["1,2,3\r", "4,5,6"]), parse_err);
    eq("CRLF boxes parsed", boxes_n, 2);
    // Negative coordinates parse (the statement does not promise them, but a
    // minus must not silently become a plus).
    ck("negative coordinates parse", parse_boxes(["-1,-2,-3", "4,5,6"]), parse_err);
    eq("negative coordinate value", bx[0], 0 - 1);
    // Too many boxes: reported, not a trap.
    let many: [str] = [];
    let i = 0;
    while (i < MAXN + 2) { many += tostring(i) + ",0,0"; i = i + 1 };
    ck("over-long input is refused", !parse_boxes(many), refusal(tostring(many.length) + " boxes"));
}

def t_example() -> void {
    // The statement's own example, and the two facts it publishes about it.
    let s = solve_lines(EX_LINES, 10);
    ck("example parses", last_parse_ok, parse_err);
    eq("example part 1 product (statement: 40)", s.product, 40);
    eq("example three largest (statement: 5,4,2)", s.c1 * 10000 + s.c2 * 100 + s.c3, 50402);
    eq("example circuits (statement: 11)", s.circuits, 11);
    eq("example sizes sum to n", s.sum_sizes, 20);
    eq("example merges", s.merged, 9);
    // The statement's full multiset: 5, 4, 2, 2 and seven 1s.  All single
    // digit, so the sizes concatenate without ambiguity.
    let sig = 0;
    let i = 0;
    while (i < cut_n) { sig = sig * 10 + cut_buf[i]; i = i + 1 };
    eq("example every circuit size (statement: 1x7,2,2,4,5)", sig, 11111112245);
    // Part 2 on the example.  216 * 117: boxes 10 and 12 of the statement's
    // list are the pair that leaves one circuit, on the 29th ordered pair.
    // The 25272 is PUBLISHED -- see README.md for the write-up that states it
    // for this same example, so both anchors are external.
    eq("example part 2 (published anchor: 25272)", s.part2, 25272);
    eq("example part 2 X values", s.last_xa * 1000 + s.last_xb, 216117);
    eq("example part 2 boxes", s.last_a * 100 + s.last_b, 1012);
    eq("example part 2 examined", s.steps_to_one, 29);
}

// The two size lists a comparison failed on, side by side and short.
def sizes_detail() -> str {
    let a = "walk [";
    let b = "union-find [";
    let i = 0;
    while (i < 8 && i < sz_n) { a = a + tostring(sz_buf[i]) + " "; i = i + 1 };
    let j = 0;
    while (j < 8 && j < cut_n) { b = b + tostring(cut_buf[j]) + " "; j = j + 1 };
    a + "] vs " + b + "] (" + tostring(sz_n) + " vs " + tostring(cut_n) + " entries)"
}

// Are the sizes left in sz_buf[0..sz_n) the ones union-find had at part 1's
// cut (cut_buf[0..cut_n))?  The one place the two methods are compared.
def sizes_match_cut() -> bool {
    let same = sz_n == cut_n;
    let i = 0;
    while (i < sz_n && same) {
        if (sz_buf[i] != cut_buf[i]) { same = false };
        i = i + 1
    };
    same
}

def t_walk_agrees() -> void {
    // The independent method: flood fill over the accepted pairs instead of
    // union-find.  Same component count, same sizes, on all three inputs.
    solve_lines(EX_LINES, 10);
    eq("example walk circuits", walk_components(20, ord_radix, 10), 11);
    ck("example walk sizes = union-find sizes", sizes_match_cut(), sizes_detail());
    solve_lines(MICRO_LINES, 4);
    eq("micro walk circuits", walk_components(5, ord_radix, 4), 2);
    ck("micro walk sizes = union-find sizes", sizes_match_cut(), sizes_detail());
    // Real input now.
    let lines: [str]? = fs.read_lines("input.txt");
    if (lines == none) { ck("real input reads", false, "read_lines none"); return };
    let rs = solve_lines(lines!, PART1_PAIRS);
    ck("real input parses", last_parse_ok, parse_err);
    eq("real walk circuits = union-find circuits", walk_components(1000, ord_radix, PART1_PAIRS), rs.circuits);
    ck("real walk sizes = union-find sizes", sizes_match_cut(), sizes_detail());
    // Part 2's pair, verified without union-find: before that connection there
    // are exactly two components and its two boxes are in different ones, and
    // after it there is exactly one.
    let t2 = rs.last_pair;
    ck("real part 2 has a final connection", t2 >= 0, "last_pair = " + tostring(t2));
    if (t2 >= 0) {
        eq("real: two circuits before the last connection", walk_components(1000, ord_radix, t2), 2);
        let ca = walk_comp[rs.last_a];
        let cb = walk_comp[rs.last_b];
        ck("real: its two boxes were in different circuits", ca != cb,
           "components " + tostring(ca) + " and " + tostring(cb));
        eq("real: one circuit after it", walk_components(1000, ord_radix, t2 + 1), 1);
    }
}

def t_orderings_agree() -> void {
    // Two different algorithms ordering the same pairs must give the same key
    // sequence and the same answers.  The heap pops ALL m pairs, not just part
    // 1's cut: part 2 needs the whole order, so a partial heap order would be
    // answering a different question.
    let lines: [str]? = fs.read_lines("input.txt");
    if (lines == none) { ck("real input reads", false, "read_lines none"); return };
    ck("real input parses", parse_boxes(lines!), parse_err);
    let b = current_boxes();
    let m = build_keys(b);
    radix_order(m);
    let rs = solve(b, ord_radix, PART1_PAIRS);
    eq("heap popped every pair", heap_order(m, m), m);
    let mono = 1;
    let bad = 0;
    let i = 1;
    let prev = pair_key[ord_heap[0]];
    while (i < m) {
        let key = pair_key[ord_heap[i]];
        if (key < prev) { mono = 0 };
        if (key != pair_key[ord_radix[i]]) { bad = bad + 1 };
        prev = key;
        i = i + 1
    };
    ck("heap keys nondecreasing", mono == 1,
       if (mono == 1) { tostring(m) + " keys in order" } else { "a key went backwards" });
    eq("heap and radix agree on all " + tostring(m) + " keys", bad, 0);
    let hs = solve(b, ord_heap, PART1_PAIRS);
    eq("part 1 under the heap ordering", hs.product, rs.product);
    eq("part 2 under the heap ordering", hs.part2, rs.part2);
    eq("part 2 pair under the heap ordering", hs.last_pair, rs.last_pair);
    eq("part 2 X values under the heap ordering", hs.last_xa * 100000 + hs.last_xb, rs.last_xa * 100000 + rs.last_xb);
}

def t_real_invariants() -> void {
    let lines: [str]? = fs.read_lines("input.txt");
    if (lines == none) { ck("real input reads", false, "read_lines none"); return };
    ck("real input parses", parse_boxes(lines!), parse_err);
    let b = current_boxes();
    let m = build_keys(b);
    radix_order(m);
    let s = solve(b, ord_radix, PART1_PAIRS);
    // Nothing here may be an absent value compared with another absent value:
    // each observation is asserted present and non-zero first.
    ck("real part 1 answer is present", s.product > 0, "product = " + tostring(s.product));
    ck("real part 2 answer is present", s.part2 > 0, "part2 = " + tostring(s.part2));
    ck("real largest circuit is present", s.c1 > 0, "c1 = " + tostring(s.c1));
    ck("real part 2 pair is present", s.last_pair >= 0 && s.last_a != s.last_b, "pair " + tostring(s.last_a) + "," + tostring(s.last_b));
    ck("real part 2 X values are non-zero", s.last_xa > 0 && s.last_xb > 0, "X " + tostring(s.last_xa) + "," + tostring(s.last_xb));
    // The three largest really are the three largest, and in range.
    ck("real three largest descend", s.c1 >= s.c2 && s.c2 >= s.c3 && s.c3 >= 1, tostring(s.c1) + "," + tostring(s.c2) + "," + tostring(s.c3));
    ck("real circuits bounded by n", s.circuits >= 1 && s.circuits <= s.n, tostring(s.circuits));
    eq("real circuit sizes sum to n", s.sum_sizes, s.n);
    // n - merges = circuits, counted the other way round, and every size >= 1.
    eq("real n - merges = circuits", s.n - s.merged, s.circuits);
    ck("real merges are within the k pairs", s.merged >= 0 && s.merged <= PART1_PAIRS, tostring(s.merged));
    // The cut is clean: the 1000th pair is strictly closer than the 1001st.
    ck("real cut is unambiguous", s.tie_at_cut == 0, tostring(s.key_at_cut) + " vs " + tostring(s.key_after_cut));
    ck("real cut keys ascend", s.key_at_cut > 0 && s.key_at_cut < s.key_after_cut, tostring(s.key_at_cut) + " vs " + tostring(s.key_after_cut));
    // Part 2 needs at least n-1 merges and no more than every pair.
    ck("real part 2 within range", s.steps_to_one >= s.n - 1 && s.steps_to_one <= s.m, tostring(s.steps_to_one));
    eq("real part 2 examined = pair index + 1", s.steps_to_one, s.last_pair + 1);
    // No two of the pairs that decide an answer share a distance, so NEITHER
    // answer depends on how a tie was broken: the radix sort's stability is a
    // convenience here, not a hidden assumption of the result.
    let lim = s.steps_to_one;
    if (lim > s.m) { lim = s.m };
    let dup = 0;
    let q = 1;
    while (q < lim) {
        if (pair_key[ord_radix[q]] == pair_key[ord_radix[q - 1]]) { dup = dup + 1 };
        q = q + 1
    };
    eq("real: no equal distances among the " + tostring(lim) + " pairs that decide an answer", dup, 0);
    // Part 1's answer with k = every pair is a single circuit of n boxes, so
    // it must be exactly n: a closed-form cross-check of the whole pipeline.
    let all = solve(b, ord_radix, s.m);
    eq("real all-pairs product = n", all.product, s.n);
    eq("real all-pairs circuits", all.circuits, 1);
    eq("real all-pairs part 2 unchanged", all.part2, s.part2);
    eq("real all-pairs final connection unchanged", all.last_pair, s.last_pair);
    // One connection makes exactly one circuit of two boxes, so the three
    // largest are 2, 1, 1 and the product is 2 -- and wiring can only merge,
    // so this is the smallest product part 1 can report.
    eq("real k=1 product", solve(b, ord_radix, 1).product, 2);
    eq("real k=1 circuits", solve(b, ord_radix, 1).circuits, 999);
}

def run_check() -> long {
    first_failure = "";
    print("day08 --check: property battery (no reference file is read)");
    print("");
    t_input();
    t_micro_pairs();
    t_micro_answers();
    t_edge_cases();
    t_example();
    t_walk_agrees();
    t_orderings_agree();
    t_real_invariants();
    // One summary, printed here.  test.report() is NOT called as well: it
    // would print a second "N of M checks passed" line for the same run.
    print("");
    print(tostring(test.checks()) + " checks, " + tostring(test.failures()) + " failed");
    if (test.failures() == 0) {
        print("day08 --check: PASS");
        0
    } else {
        print("day08 --check: FAIL, first failure: " + first_failure);
        1
    }
}

// ── main ────────────────────────────────────────────────────────────────────

def main() -> long {
    let args = argv();
    let mode = 0;            // 0 = answers, 1 = --check, 2 = --help
    let path = "input.txt";
    let pairs = PART1_PAIRS;
    let i = 1;
    let bad = false;
    while (i < args.length) {
        let a = args[i];
        if (a == "--help" || a == "-h") {
            mode = 2;
        } else if (a == "--check") {
            mode = 1;
        } else if (a == "--input" && i + 1 < args.length) {
            i = i + 1;
            path = args[i];
        } else if (a == "--pairs" && i + 1 < args.length) {
            i = i + 1;
            let v = coord_value(args[i]);
            if (v == none) {
                print("day08: --pairs wants a count of connections");
                bad = true;
            } else {
                pairs = v!
            }
        } else if (a == "--input" || a == "--pairs") {
            print("day08: " + a + " needs a value");
            bad = true;
        } else {
            print("day08: unknown argument '" + a + "' (try --help)");
            bad = true;
        };
        i = i + 1
    };
    if (bad) { return 2 };
    if (mode == 2) {
        print_usage();
        return 0
    };
    if (mode == 1) { return run_check() };
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        print("day08: cannot read " + path);
        return 1
    };
    let ls = lines!;
    if (!parse_boxes(ls)) {
        print("day08: " + path + ": " + parse_err);
        return 1
    };
    if (pairs > pair_total(boxes_n)) {
        print("day08: " + tostring(boxes_n) + " boxes have only " + tostring(pair_total(boxes_n)) + " pairs");
        return 1
    };
    report(path, pairs)
};

exit(main())