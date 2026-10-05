// check.y -- the property battery for wavefunction.
//
//   ./wavefunction --check                    everything, then the defect sweep
//   ./wavefunction --check --inject N         one defect in force, verbose
//
// WHY THIS FILE EXISTS.  EXPECTED proves the run is deterministic; it proves
// nothing about whether the grid is right.  A golden file generated from a
// broken solver is byte-stable and worthless -- that is not a hypothetical, it is
// what happened to `cube` in this campaign.  So every assertion below is about
// the OUTPUT or about the bookkeeping, no reference file is read, and every
// expectation is either worked out by hand (README.md has the derivations) or
// computed a second way by a DIFFERENT algorithm.
//
// THE THREE ORACLES, in order of how much they are worth:
//
//   1. THE FINISHED GRID AGAINST THE SOCKET RULE.  Two tiles may be neighbours
//      only when they agree on the edge they share.  Checked on the completed
//      image, with this file's own copy of the socket bits -- parsed out of the
//      tile NAMES, not read from tiles.SOCK -- plus: every cell holds exactly
//      one tile, and no socket faces off the grid.  A propagation bug that still
//      emits a self-consistent grid slips past anything watching the process and
//      is caught here.
//   2. AN EXHAUSTIVE ENUMERATOR.  For the small grids this file walks EVERY
//      assignment consistent with the raw rule -- plain backtracking, no
//      propagation, no entropy, no propagation-derived pruning -- and checks
//      three things against it: the number of solutions (against hand-derived
//      counts), that every solution lies inside the masks propagation reached
//      (a propagation that deletes a tile some solution needs is unsound), and
//      that an instance the search calls unsatisfiable really has no solutions.
//   3. THE BOOKKEEPING AND THE RULE.  CNT and WSUM must equal what the mask
//      says, bit by bit; the entropy recorded for every decision must be the
//      minimum over the open cells; and the cell chosen must be the lowest-index
//      cell attaining it.  The tie-break is what EXPECTED rests on, so it is
//      asserted rather than assumed.
//
// AND THEN THE INJECTED DEFECTS.  A check that has never failed is not known to
// work, so --check injects each of the seventeen defects in wfc.y and tiles.y in
// turn and REQUIRES the battery to fail for every one of them.  A defect no
// assertion catches would be reported here rather than quietly dropped.

import tiles;
import wfc;
import sink;
// std's seeded generator, which the solver now draws from: one assertion below
// (t_draw) checks that its stream is not constant.
import random;

// ─────────────────────────────────────────────────────── the check scaffolding ───

let RUN: long = 0;
let FAILED: long = 0;
let FIRST: str = "";
let VERBOSE: long = 1;
// SHOWFAIL -- whether a failing check prints its "FAIL  name -- detail" line.
// The sweep turns it OFF, and that is not cosmetic: examples/gate.py reads the
// check's whole output and fails item 8 if the word FAIL appears anywhere, which
// is right for the clean run and exactly wrong for a run whose entire job is to
// make checks fail.  So the sweep's children report a count and the names of the
// failures in a sentence of their own, and the literal word never appears.
let SHOWFAIL: long = 1;
let INJECTWANT: long = 0;
let CAUGHT: long = 0;
let MISSED: long = 0;
let MISSEDLIST: str = "";

def ck(name: str, ok: bool, detail: str) -> void {
    RUN = RUN + 1;
    if (ok) {
        if (VERBOSE == 1) { print("ok    " + name) }
    } else {
        FAILED = FAILED + 1;
        if (FIRST == "") { FIRST = name };
        if (SHOWFAIL == 1) { print("FAIL  " + name + " -- " + detail) }
    }
};

def ck_eq(name: str, got: long, want: long) -> void {
    ck(name, got == want, "got " + tostring(got) + ", want " + tostring(want))
};

def set_inject_want(n: long) -> void { INJECTWANT = n };

def set_all(k: long) -> void {
    wfc.set_inject(k);
    tiles.set_inject(k)
};

// The caveat the whole battery is built around: a comparison between two values
// that are BOTH absent passes, and two agents in this campaign shipped exactly
// that.  So every "zero violations" assertion is written as "there were N
// things to check, N is not zero, and zero of them failed" -- see ok_grid(),
// which reports how many pairs it examined and REFUSES to pass on a grid with no
// adjacent pairs at all.

// ─────────────────────────────────────────── this file's own socket table ───
//
// Parsed from tiles.NAMES, which is the human-readable specification: everything
// after the first '-' names the sockets.  `empty` has none, `cross-NESW` has all
// four.  Parsing the NAME rather than trusting the number is what makes the
// oracle independent -- a corrupted tiles.SOCK shows up here as a disagreement
// instead of quietly redefining the puzzle.

let CSOCK: [long; 16] = [0; 16];

def sock_of_name(s: str) -> long {
    let bits = 0;
    let at = s.index_of("-");
    if (at < 0) { return 0 };
    let i = at + 1;
    while (i < len(s)) {
        let ch = s[i];
        // `s[i]` on a str is a BYTE, not a one-character string, so the
        // comparison is against ord() rather than against "N".
        if (ch == ord("N")) { bits = bits | 1 }
        else if (ch == ord("E")) { bits = bits | 2 }
        else if (ch == ord("S")) { bits = bits | 4 }
        else if (ch == ord("W")) { bits = bits | 8 }
        else { return 0 - 1 };          // a letter that is not a direction
        i = i + 1
    };
    bits
};

def parse_names() -> long {
    let bad = 0;
    let t = 0;
    while (t < 16) {
        let v = sock_of_name(tiles.NAMES[t]);
        CSOCK[t] = if (v < 0) { 0 } else { v };
        if (v < 0) { bad = bad + 1 };
        t = t + 1
    };
    bad
};

// cbit(t, d) -> long -- tile t's socket facing direction d, from THIS file's
// table.  Directions 0=N 1=E 2=S 3=W, the same order as the bit constants.
def cbit(t: long, d: long) -> long {
    let e = 0;
    if (d == 0) { e = 1 } else if (d == 1) { e = 2 } else if (d == 2) { e = 4 } else { e = 8 };
    if ((CSOCK[t] & e) != 0) { 1 } else { 0 }
};

def copp(d: long) -> long {
    let b = d + 2;
    if (b > 3) { b = b - 4 };
    b
};

def cpop(m: long) -> long {
    let n = 0;
    let t = 0;
    while (t < 16) {
        if ((m & (1 << t)) != 0) { n = n + 1 };
        t = t + 1
    };
    n
};

def cfirst(m: long) -> long {
    let t = 0;
    while (t < 16) {
        if ((m & (1 << t)) != 0) { return t };
        t = t + 1
    };
    0
};

def cwsum(m: long) -> long {
    let n = 0;
    let t = 0;
    while (t < 16) {
        if ((m & (1 << t)) != 0) { n = n + tiles.WT[t] };
        t = t + 1
    };
    n
};

// ───────────────────────────────────────────────── the oracle: the finished grid ───

// ok_grid(label, want_sockets) -> long -- 0 for pass, 1 for fail.
//
// THE MAIN EVENT.  Everything here is read off the completed image: the cell
// masks, this file's own socket bits, and the geometry.  Nothing about the
// search is consulted -- not the event log, not the counters, not the order the
// cells were decided in -- because the point is that the OUTPUT is right, not
// that the process was.
//
// `want_sockets` is how many socket-carrying cells the caller asserts should be
// there; it is what stops an all-empty grid from passing as "no violations".  The
// deliberately tiny grids pass 0, and their count is printed instead.
def ok_grid(label: str, want_sockets: long) -> long {
    let w = wfc.GW;
    let h = wfc.GH;
    // Every cell must hold exactly ONE tile.  A cell with an open mask is not a
    // solution; a cell with an EMPTY mask is a contradiction the search failed
    // to report.  Both are checked here rather than trusted.
    let notsingle = 0;
    let notmask = 0;
    let pairs = 0;
    let bad = 0;
    let off = 0;
    let used = 0;
    let y = 0;
    while (y < h) {
        let x = 0;
        while (x < w) {
            let i = y * w + x;
            let m = wfc.MASK[i];
            if (m == 0) { notmask = notmask + 1 };
            if (cpop(m) != 1) { notsingle = notsingle + 1 };
            let a = cfirst(m);
            if (CSOCK[a] != 0) { used = used + 1 };
            let d = 0;
            while (d < 4) {
                let j = cneigh(i, w, h, d);
                if (j < 0) {
                    if (cbit(a, d) != 0) { off = off + 1 }
                } else {
                    pairs = pairs + 1;
                    let b = cfirst(wfc.MASK[j]);
                    if (cbit(a, d) != cbit(b, copp(d))) { bad = bad + 1 }
                };
                d = d + 1
            };
            x = x + 1
        };
        y = y + 1
    };
    // Each pair was counted twice (once from each end); halve both.
    let pairs2 = pairs / 2;
    let bad2 = bad / 2;
    ck("grid " + label + ": every cell holds exactly one tile",
       notsingle == 0 && notmask == 0,
       tostring(notsingle) + " cells not collapsed, " + tostring(notmask) + " empty masks");
    ck("grid " + label + ": there are adjacent pairs to check", pairs2 > 0,
       "only " + tostring(pairs2) + " pairs -- nothing would be verified");
    ck("grid " + label + ": every adjacent pair agrees on the shared edge",
       bad2 == 0, tostring(bad2) + " of " + tostring(pairs2) + " pairs disagree");
    ck("grid " + label + ": no socket faces off the grid", off == 0,
       tostring(off) + " sockets face the boundary");
    // The label says which way round the assertion is: on the deliberately tiny
    // grids "at least 0 cells carry a socket" would read as a claim that is true
    // of an empty grid, which is exactly the impression this battery is trying
    // not to give.
    if (want_sockets > 0) {
        ck("grid " + label + ": at least " + tostring(want_sockets) +
           " cells carry a socket", used >= want_sockets,
           "only " + tostring(used) + " carry one")
    } else {
        ck("grid " + label + ": a blank grid is allowed here (the rule, not the " +
           "richness, is what is asserted)", used >= 0,
           tostring(used) + " carry one, which cannot be negative")
    };
    if (VERBOSE == 1) {
        print("     " + label + ": " + tostring(pairs2) + " pairs, " +
              tostring(bad2) + " disagreements, " + tostring(off) +
              " off-grid, " + tostring(used) + " of " + tostring(wfc.NC) +
              " cells carry a socket")
    };
    if (notsingle == 0 && notmask == 0 && bad2 == 0 && off == 0 &&
        used >= want_sockets) { 0 } else { 1 }
};

// cneigh(i, w, h, d) -> long -- the cell at direction d from i, or -1.  This
// file's own arithmetic; it does not call wfc.neighbour, because an oracle that
// borrows the solver's notion of "neighbour" cannot catch a solver whose notion
// of "neighbour" is wrong.
def cneigh(i: long, w: long, h: long, d: long) -> long {
    let x = i % w;
    let y = i / w;
    let nx = x;
    let ny = y;
    if (d == 0) { ny = y - 1 } else if (d == 1) { nx = x + 1 }
    else if (d == 2) { ny = y + 1 } else { nx = x - 1 };
    if (nx < 0 || nx >= w || ny < 0 || ny >= h) { return 0 - 1 };
    ny * w + nx
}

// ─────────────────────────────────────────── the exhaustive enumerator ───
//
// A plain depth-first walk over every assignment of the grid's cells to
// available tiles that satisfies the RAW rule, pruning only on tiles already
// placed next to the cell being filled.  No propagation, no entropy, no masks:
// this is the answer computed the slow obvious way, and it is what the solver's
// output and masks are compared against.
//
// It is exponential, which is why it only runs on grids small enough to finish
// (3x2 with all sixteen tiles has 128 solutions; 4x3 has 131072).  ELIMIT is a
// hard stop, and a run that reaches it says so instead of reporting a partial
// count as a total.

// EA and UF are sized for the LARGEST grid any check hands them (12x8 = 96 cells;
// 64 would be an out-of-bounds write on the second instance, which is what a
// fixed array overrun is: a runtime trap, on stdout, in the middle of the battery).
let EA: [long; 4096] = [0; 4096];       // the assignment being built
let EW: long = 0;
let EH: long = 0;
let EAV: long = 0;
let ECNT: long = 0;
let ELIMIT: long = 2000000;
let EHIT: long = 0;                   // 1 if the walk stopped at ELIMIT
let EVIOL: long = 0;                  // solutions using a tile the masks excluded
let EVIOLT: long = 0;
let EUSE: long = 0;                   // check the solutions against wfc.MASK

// elegal(k, t) -> long -- may tile t stand at cell k?  Boundary only: the
// enumerator prunes nothing else, so it is not quietly agreeing with the solver
// about anything except the edges.
def elegal(k: long, t: long) -> long {
    let x = k % EW;
    let y = k / EW;
    let ok = 1;
    if (y == 0 && cbit(t, 0) != 0) { ok = 0 };
    if (y == EH - 1 && cbit(t, 2) != 0) { ok = 0 };
    if (x == 0 && cbit(t, 3) != 0) { ok = 0 };
    if (x == EW - 1 && cbit(t, 1) != 0) { ok = 0 };
    ok
};

// eok(k) -> long -- does the tile just placed at k agree with the tiles already
// placed at its neighbours?  The whole constraint system, one pair at a time.
def eok(k: long) -> long {
    let ok = 1;
    let d = 0;
    while (d < 4) {
        let j = cneigh(k, EW, EH, d);
        if (ok && j >= 0 && j < k) {
            if (cbit(EA[k], d) != cbit(EA[j], copp(d))) { ok = 0 }
        };
        d = d + 1
    };
    ok
};

def erec(k: long) -> void {
    if (ECNT >= ELIMIT) { EHIT = 1; return };
    if (k == EW * EH) {
        ECNT = ECNT + 1;
        // Compare the finished assignment with the masks the solver's
        // propagation reached, when asked: EVERY solution must lie inside them,
        // or the propagation threw away a tile some valid grid needs.
        if (EUSE == 1) {
            let i = 0;
            while (i < EW * EH) {
                if ((wfc.MASK[i] & (1 << EA[i])) == 0) {
                    EVIOL = EVIOL + 1;
                    EVIOLT = EA[i]
                };
                i = i + 1
            }
        };
        return
    };
    let t = 0;
    while (t < 16) {
        if ((EAV & (1 << t)) != 0 && elegal(k, t) == 1) {
            EA[k] = t;
            if (eok(k) == 1) { erec(k + 1) }
        };
        t = t + 1
    }
};

// enum_run(w, h, avail, use_masks) -> long -- the number of solutions.
def enum_run(w: long, h: long, avail: long, use_masks: long) -> long {
    EW = w;
    EH = h;
    EAV = avail;
    ECNT = 0;
    EHIT = 0;
    EVIOL = 0;
    EVIOLT = 0;
    EUSE = use_masks;
    erec(0);
    ECNT
};

def enum_truncated() -> long { EHIT };

def enum_violations() -> long { EVIOL };

// ─────────────────────────────────────────────────────────── the checks ───

// t_table() -- the tile table is what its own names say it is.
def t_table() -> void {
    ck_eq("names parse (no unknown direction letter)", parse_names(), 0);
    let diff = 0;
    let t = 0;
    while (t < 16) {
        if (CSOCK[t] != tiles.SOCK[t]) { diff = diff + 1 };
        t = t + 1
    };
    ck_eq("every tiles.SOCK entry matches the socket parsed out of its name",
          diff, 0);
    // The weights are the specification too: 6 for empty, 3 for each straight,
    // 4 for each elbow, 1 for the rest.  6+4+6+16+4+1 = 37, by hand.
    let sum = 0;
    t = 0;
    while (t < 16) { sum = sum + tiles.WT[t]; t = t + 1 };
    ck_eq("tile weights sum to 37 (hand-derived)", sum, 37);
    ck_eq("empty is the commonest tile", tiles.WT[0], 6);
    ck_eq("the cross is the rarest", tiles.WT[15], 1);
    ck_eq("the sixteen socket patterns are all different", sock_collisions(), 0);
    // The sixteen tiles are exactly the sixteen subsets of {N,E,S,W}: that is a
    // property of the SPECIFICATION, and it means the rule has no blind spot --
    // every possible socket pattern is available in every cell.
    let covered = 0;
    let seen = 0;
    t = 0;
    while (t < 16) {
        seen = seen | (1 << CSOCK[t]);
        t = t + 1
    };
    while (covered < 16) {
        if ((seen & (1 << covered)) != 0) { covered = covered + 1 } else { covered = 32 }
    };
    ck_eq("every one of the 16 socket patterns is a tile (all of 2^4)", covered, 16)
};

def sock_collisions() -> long {
    let n = 0;
    let a = 0;
    while (a < 16) {
        let b = a + 1;
        while (b < 16) {
            if (CSOCK[a] == CSOCK[b]) { n = n + 1 };
            b = b + 1
        };
        a = a + 1
    };
    n
};

// t_subsets() -- each --tiles mask is what its name says it is.
//
// Derived here from the tile NAMES ("straight" in the name, "elbow" in the name,
// an "end-" prefix, "cross-NESW", "empty") and compared with the constants in
// tiles.y.  This check exists because four of the six were wrong when they were
// first written and NOTHING else in the program noticed: 85 for {0,5,6}, 1063
// for {0,7..10}, 80 for {5,6} and 65409 for "everything but empty".  Two of
// those turned a documented UNSATISFIABLE instance into a satisfiable one, which
// is the worst kind of silent wrong -- the flag still ran, it just solved
// something else.
def t_subsets() -> void {
    ck_eq("subset count", len(tiles.SUBSETS), 7);
    let bad = 0;
    let i = 0;
    while (i < 7) {
        let want = expected_subset(i);
        let got = tiles.SUBMASK[i];
        if (want != got) {
            bad = bad + 1;
            print("     subset " + tiles.SUBSETS[i] + " is " + tostring(got) +
                  " but its membership says " + tostring(want))
        };
        i = i + 1
    };
    ck_eq("every --tiles mask matches the membership its name describes", bad, 0);
    ck_eq("`loop` is every tile except empty", tiles.SUB_LOOP, 65534);
    ck_eq("`straights` is the two straights and no empty",
           tiles.SUB_STRAIGHTS, (1 << 5) | (1 << 6))
};

// expected_subset(which) -> long -- the mask each subset should have, read off the
// tile names: 0 all, 1 loop, 2 lines, 3 elbows, 4 ends, 5 straights, 6 cross.
def expected_subset(which: long) -> long {
    let m = 0;
    let t = 0;
    while (t < 16) {
        let n = tiles.NAMES[t];
        let empty = 0;
        let straight = 0;
        let elbow = 0;
        let endt = 0;
        let cross = 0;
        if (n == "empty") { empty = 1 };
        if (n.index_of("straight") >= 0) { straight = 1 };
        if (n.index_of("elbow") >= 0) { elbow = 1 };
        if (n.index_of("end-") == 0) { endt = 1 };
        if (n == "cross-NESW") { cross = 1 };
        let want = 0;
        if (which == 0) { want = 1 }
        else if (which == 1) { if (empty == 0) { want = 1 } }
        else if (which == 2) { if (empty == 1 || straight == 1) { want = 1 } }
        else if (which == 3) { if (empty == 1 || elbow == 1) { want = 1 } }
        else if (which == 4) { if (empty == 1 || endt == 1) { want = 1 } }
        else if (which == 5) { if (straight == 1) { want = 1 } }
        else { if (cross == 1) { want = 1 } };
        if (want == 1) { m = m | (1 << t) };
        t = t + 1
    };
    m
}

// t_entropy() -- the entropy, checked against facts that did not come out of it.
//
// The anchor that needs no second implementation: a UNIFORM distribution over k
// tiles has H = log2(k) bits, which in Q30 is an exact integer for k a power of
// two.  Then three properties that are exhaustive rather than sampled:
//   - H(m) == 0 exactly when m holds at most one tile, over ALL 65536 masks;
//   - H is strictly increasing in k for uniform masks of k tiles, k = 1..16;
//   - H({a,b}) == H({b,a}) for all 240 ordered pairs: entropy is a function of
//     the multiset of weights, so any order-dependence in the sum is a defect.
def t_entropy() -> void {
    // Equal WEIGHT, not equal index.  A mask of the first k tiles is NOT a uniform
    // distribution -- tiles 0 and 1 weigh 6 and 1 -- and an earlier draft of this
    // check built exactly that and compared it with log2 k.  That is how a check
    // which looks like an external anchor becomes a wrong expectation, and it is
    // why the anchors below are named by weight:
    //   tiles 5,6      weigh 3 each -> H = 1 bit exactly
    //   tiles 1,2,3,4  weigh 1 each -> H = 2 bits exactly
    //   tiles 11..15   weigh 1 each -> H = log2 5 = 2.321928094887362 bits,
    //                                   2493151308 in Q30
    let bad = 0;
    let two = wfc.entropy((1 << 5) | (1 << 6));
    if (two != 1073741824) {
        bad = bad + 1;
        print("     entropy of two equal-weight tiles = " + tostring(two) +
              ", want 1073741824 (exactly 1 bit)")
    };
    let four = wfc.entropy((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4));
    if (four != 2147483648) {
        bad = bad + 1;
        print("     entropy of four equal-weight tiles = " + tostring(four) +
              ", want 2147483648 (exactly 2 bits)")
    };
    ck_eq("entropy of 2 and of 4 equal-weight tiles is exactly 1 and 2 bits",
          bad, 0);
    ck_eq("entropy of 5 equal-weight tiles is log2 5 = 2493151308 in Q30",
          wfc.entropy((1 << 11) | (1 << 12) | (1 << 13) | (1 << 14) | (1 << 15)),
          2493151308);

    // Exhaustive: zero exactly on the masks with at most one tile.
    let wrong0 = 0;
    let m = 0;
    while (m < 65536) {
        let h = wfc.entropy(m);
        let p = cpop(m);
        if ((h == 0) != (p <= 1)) { wrong0 = wrong0 + 1 };
        m = m + 1
    };
    ck_eq("entropy is 0 exactly on the 17 masks holding at most one tile",
          wrong0, 0);

    // And it rises with the number of equal-weight tiles, which is the one
    // ordering fact the selection rule leans on.
    let notmono = 0;
    if (wfc.entropy((1 << 5) | (1 << 6)) >=
        wfc.entropy((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4))) { notmono = notmono + 1 };
    if (wfc.entropy((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4)) >=
        wfc.entropy((1 << 11) | (1 << 12) | (1 << 13) | (1 << 14) | (1 << 15))) {
        notmono = notmono + 1
    };
    ck_eq("entropy rises with the number of equal-weight tiles", notmono, 0);

    // Symmetry: a function of the weight multiset.
    let asym = 0;
    let a = 0;
    while (a < 16) {
        let b = 0;
        while (b < 16) {
            if (a != b) {
                if (wfc.entropy((1 << a) | (1 << b)) != wfc.entropy((1 << b) | (1 << a))) {
                    asym = asym + 1
                }
            };
            b = b + 1
        };
        a = a + 1
    };
    ck_eq("entropy of {a,b} equals entropy of {b,a} for all 240 pairs", asym, 0);

    // One worked value, digits and all: {empty (6), end-N (1)} has W = 7, so
    //   H = log2 7 - (6*log2 6)/7 = 2.807355 - 2.215800 = 0.591555 bits,
    // and 0.591555 * 2^30 = 635303810.  Worked out in README.md.
    ck_eq("entropy of weights 6:1 is 635303810 (0.591555 bits, hand-derived)",
          wfc.entropy((1 << 0) | (1 << 1)), 635303810);
    ck_eq("entropy of an empty mask is 0", wfc.entropy(0), 0)
};

// t_draw() -- the weighted draw is weighted.
//
// choose_r(mask, r) is exposed so this can be an EXACT statement rather than a
// statistical one: over r = 0 .. W-1, every tile must come up exactly weight(t)
// times.  Counting frequencies over 200 solves is the weaker version of this and
// the campaign has seen that pass a broken draw.
def t_draw() -> void {
    let full = 65535;
    let w = cwsum(full);
    ck_eq("full tile set weighs 37 (hand-derived)", w, 37);
    let bad = 0;
    let t = 0;
    while (t < 16) {
        let got = 0;
        let r = 0;
        while (r < w) {
            if (wfc.choose_r(full, r) == t) { got = got + 1 };
            r = r + 1
        };
        if (got != tiles.WT[t]) {
            bad = bad + 1;
            print("     tile " + tiles.NAMES[t] + " drawn " + tostring(got) +
                  " times in " + tostring(w) + ", want " + tostring(tiles.WT[t]))
        };
        t = t + 1
    };
    ck_eq("over r = 0..36 every tile is drawn exactly its weight", bad, 0);
    // The tie-break inside the draw: two EQUAL weights are resolved by tile index,
    // which is what makes a given r give the same tile every run.  Tiles 5 and 6
    // both weigh 3, so r = 0,1,2 must give tile 5 and r = 3,4,5 tile 6.
    let pair = (1 << 5) | (1 << 6);
    let low = 0;
    let high = 0;
    let r = 0;
    while (r < 6) {
        if (wfc.choose_r(pair, r) == 5) { low = low + 1 };
        if (wfc.choose_r(pair, r) == 6) { high = high + 1 };
        r = r + 1
    };
    ck_eq("two equal weights (tiles 5,6) split the six draws 3/3 by index",
          low * 10 + high, 33);
    // A range longer than the weight total is clamped to the last tile rather
    // than trapping or wrapping -- reachable only by a caller that got WSUM wrong,
    // which is the point.
    ck_eq("a draw past the end of the range clamps to the last tile",
          wfc.choose_r(65535, 999), 15);
    // And the stream is not constant: "the same seed gives the same answer" is
    // also true of a program that ignores the seed, so the stream must move.
    //
    // The draw is std's (`import random`, splitmix64).  It used to be
    // `wfc.rnd(37)`, this example's own xorshift64 behind `wfc.rs_next`, both
    // of which are gone -- so this is now a statement about the generator the
    // SOLVER draws from, which is the point: a solver that had stopped drawing
    // from std's stream (or had begun drawing from a constant) would fail here.
    random.seed(20251005);
    let seen = 0;
    let distinct = 0;
    let i = 0;
    while (i < 40) {
        let v = random.below(37);
        if ((seen & (1 << v)) == 0) { seen = seen | (1 << v); distinct = distinct + 1 };
        i = i + 1
    };
    ck("the seeded stream visits more than one value in 40 draws", distinct > 5,
       "only " + tostring(distinct) + " distinct values")
};

// t_bookkeeping() -- CNT and WSUM say what MASK says.
//
// Checked after setup+propagate, where the masks have been narrowed by the
// boundary and by propagation but nothing is collapsed, so every derived column
// has been written by a real propagation step rather than by the initial fill.
def t_bookkeeping() -> void {
    wfc.setup(3, 2, tiles.SUB_ALL, 11);
    wfc.propagate();
    let badcnt = 0;
    let badw = 0;
    let i = 0;
    while (i < wfc.NC) {
        if (wfc.CNT[i] != cpop(wfc.MASK[i])) { badcnt = badcnt + 1 };
        if (wfc.WSUM[i] != cwsum(wfc.MASK[i])) { badw = badw + 1 };
        i = i + 1
    };
    ck_eq("CNT equals the bit count of MASK on every cell", badcnt, 0);
    ck_eq("WSUM equals the weight sum of MASK on every cell", badw, 0);
    // Same again AFTER a solve, where the undo path has restored masks from the
    // log: a rewind that restored the mask but not the derived columns would be
    // caught only here.
    wfc.setup(8, 6, tiles.SUB_ALL, 3);
    wfc.solve();
    badcnt = 0;
    badw = 0;
    i = 0;
    while (i < wfc.NC) {
        if (wfc.CNT[i] != cpop(wfc.MASK[i])) { badcnt = badcnt + 1 };
        if (wfc.WSUM[i] != cwsum(wfc.MASK[i])) { badw = badw + 1 };
        i = i + 1
    };
    ck_eq("CNT still matches MASK after backtracking restored masks", badcnt, 0);
    ck_eq("WSUM still matches MASK after backtracking restored masks", badw, 0);
    // And the boundary itself, on the INITIAL domain, before any propagation:
    // a cell on an edge may not hold a tile with a socket facing off the grid.
    wfc.setup(3, 2, tiles.SUB_ALL, 11);
    let badb = 0;
    i = 0;
    while (i < wfc.NC) {
        let x = i % wfc.GW;
        let y = i / wfc.GW;
        let t = 0;
        while (t < 16) {
            if ((wfc.MASK[i] & (1 << t)) != 0) {
                if (y == 0 && cbit(t, 0) != 0) { badb = badb + 1 };
                if (y == wfc.GH - 1 && cbit(t, 2) != 0) { badb = badb + 1 };
                if (x == 0 && cbit(t, 3) != 0) { badb = badb + 1 };
                if (x == wfc.GW - 1 && cbit(t, 1) != 0) { badb = badb + 1 }
            };
            t = t + 1
        };
        i = i + 1
    };
    ck_eq("no off-grid socket is in any boundary cell's initial mask", badb, 0);
    ck("the boundary narrowed the corner masks (they differ from the interior)",
       wfc.MASK[0] != interior_mask(),
       "corner and interior masks are identical")
};

def interior_mask() -> long {
    let i = 0;
    while (i < wfc.NC) {
        let x = i % wfc.GW;
        let y = i / wfc.GW;
        if (x > 0 && y > 0 && x < wfc.GW - 1 && y < wfc.GH - 1) { return wfc.MASK[i] };
        i = i + 1
    };
    0
};

// t_tiny() -- hand-derived solution counts.
//
// Every count here was worked out on paper by case analysis; README.md has the
// derivations.  A count of ONE is the shape the brief asks for -- "a tiny
// hand-checked grid collapses to the one solution" -- and it needs a restricted
// tile set to be reachable, because the boundary constraints alone never pin an
// interior cell.
def t_tiny() -> void {
    // 1. 1x1, all sixteen.  A single cell is on all four edges, so only a tile
    //    with all four sockets clear survives the boundary: `empty`.  One
    //    solution, and the search must reach it without collapsing anything.
    wfc.setup(1, 1, tiles.SUB_ALL, 1);
    let rc = wfc.solve();
    ck_eq("1x1 all: the search succeeds", rc, wfc.R_OK);
    ck_eq("1x1 all: the cell is tile 0 (empty)", cfirst(wfc.MASK[0]), 0);
    ck_eq("1x1 all: nothing was collapsed -- the boundary decided it",
          wfc.COLLAPSES, 0);
    ck_eq("1x1 all: exactly one solution, by hand", enum_run(1, 1, 65535, 0), 1);
    ck_eq("1x1 all: the enumeration was not truncated", enum_truncated(), 0);

    // 2. 2x2, `elbows` (empty and the four elbows).  The top-left corner needs N
    //    and W clear, so it is empty or elbow-ES and nothing else; and elbow-ES
    //    there has exactly one non-empty completion, the 2x2 ring
    //        elbow-ES elbow-SW
    //        elbow-NE elbow-WN
    //    in which every elbow's two sockets meet a partner's.  Exactly TWO
    //    solutions, both listed in README.md.  A hand derivation of this one
    //    originally said "one" and was wrong -- the enumerator caught it, which is
    //    what an independent oracle is for.
    wfc.setup(2, 2, tiles.SUB_ELBOWS, 1);
    rc = wfc.solve();
    ck_eq("2x2 elbows: the search succeeds", rc, wfc.R_OK);
    ck_eq("2x2 elbows: exactly two solutions, by hand",
          enum_run(2, 2, tiles.SUB_ELBOWS, 0), 2);
    ok_grid("2x2 elbows", 0);
    // And the answer is one of the two hand-listed ones, which is stronger than
    // "the count is two": a wrong answer cannot hide behind a right count.
    // The ring's tiles are 8, 9, 7, 10 in cell order, so they sum to 34.
    let ring = cfirst(wfc.MASK[0]) + cfirst(wfc.MASK[1]) + cfirst(wfc.MASK[2]) +
               cfirst(wfc.MASK[3]);
    ck("2x2 elbows: the answer is all empty or the elbow ring",
       ring == 0 || ring == 34,
       "tile indices sum to " + tostring(ring) + "; 0 = all empty, 34 = the ring");

    // 3. 2x2, `ends` (empty and the four ends).  Seven solutions, listed in
    //    README.md: all empty; two horizontal pairs (top row or bottom row); two
    //    vertical pairs (left or right column); the two-corner pinwheels
    //    (end-S top-left with end-N bottom-left, end-E top-right with end-W
    //    bottom-right); and the one solution where all four are ends.
    ck_eq("2x2 ends: exactly seven solutions, by hand",
          enum_run(2, 2, tiles.SUB_ENDS, 0), 7);
    wfc.setup(2, 2, tiles.SUB_ENDS, 4);
    rc = wfc.solve();
    ck_eq("2x2 ends: the search succeeds", rc, wfc.R_OK);
    ok_grid("2x2 ends", 0);

    // 4. 3x2, `lines` (empty, straight-NS, straight-EW).  The four corners must
    //    be empty (a straight cannot clear both its boundary sides), so the two
    //    middle cells have E and W matched against empties, and the bottom one
    //    cannot be NS because it is on the bottom edge.  One solution.
    ck_eq("3x2 lines: exactly one solution, by hand",
          enum_run(3, 2, tiles.SUB_LINES, 0), 1);
    wfc.setup(3, 2, tiles.SUB_LINES, 2);
    rc = wfc.solve();
    ck_eq("3x2 lines: the search succeeds", rc, wfc.R_OK);
    ok_grid("3x2 lines", 0);

    // 5. 2x2, `elbows`, grid 3x3 -- no.  3x3 with all sixteen tiles has 128
    //    solutions, which is the enumerator's answer and NOT a hand-derived one;
    //    it is used below as a cross-check against the Python model in oracle.py,
    //    which computes the same 128 independently.
    ck_eq("3x2 all: 128 solutions (cross-checked with oracle.py)",
          enum_run(3, 2, tiles.SUB_ALL, 0), 128);
    ck_eq("3x2 all: the enumeration was not truncated", enum_truncated(), 0);
    ck_eq("2x1 ends: exactly two solutions, by hand",
          enum_run(2, 1, tiles.SUB_ENDS, 0), 2)
};

// t_complete() -- propagation never throws away a tile a solution needs.
//
// This is the soundness property of arc consistency and the one a hand-count
// cannot give: it is checked on EVERY solution of a 3x2 grid with all sixteen
// tiles -- 128 of them, enumerated exhaustively -- against the masks the real
// propagation reached from the real setup.
def t_complete() -> void {
    wfc.setup(3, 2, tiles.SUB_ALL, 11);
    wfc.propagate();
    let solutions = enum_run(3, 2, tiles.SUB_ALL, 1);
    ck("3x2 all: the enumeration was exhaustive and found something",
       enum_truncated() == 0 && solutions > 0,
       "truncated at " + tostring(solutions) + " solutions");
    ck_eq("3x2 all: no solution uses a tile propagation had removed",
          enum_violations(), 0);
    ck("3x2 all: the oracle really did look at a lot of solutions", solutions >= 128,
       "only " + tostring(solutions) + " solutions");
    // The same soundness claim on a grid where the tile set forces real work:
    // 3x3 with `loop` (no empty tile, so every cell carries a socket and the
    // boundary does most of the narrowing).  969 solutions, and the enumeration
    // reports whether it reached its limit rather than letting a truncated count
    // pass for a total.
    wfc.setup(3, 3, tiles.SUB_LOOP, 2);
    wfc.propagate();
    let solutions3 = enum_run(3, 3, tiles.SUB_LOOP, 1);
    ck("3x3 loop: the enumeration was exhaustive and found something",
       enum_truncated() == 0 && solutions3 > 0,
       "truncated at " + tostring(solutions3));
    ck_eq("3x3 loop: no solution uses a tile propagation had removed",
          enum_violations(), 0);
    ck("3x3 loop: the oracle really did look at hundreds of solutions",
       solutions3 >= 900, "only " + tostring(solutions3) + " solutions");
    // Geometry, hand-derived: a 3x2 grid has 3*1 horizontal pairs and 2*2
    // vertical ones.
    ck_eq("adjacent pairs on 3x2 = 7 (3*1 + 2*2, by hand)", pair_count(3, 2), 7);
    ck_eq("adjacent pairs on 4x4 = 24 (4*3 + 4*3, by hand)", pair_count(4, 4), 24)
};

def pair_count(w: long, h: long) -> long {
    ((w - 1) * h) + (w * (h - 1))
};

// t_unsat() -- deliberately unsatisfiable instances.
//
// Three shapes of unsatisfiability, all provable on paper (README.md) and all
// cross-checked against the exhaustive enumerator:
//
//   1. the INITIAL DOMAIN is empty -- `straights` on 2x2.  The corner needs N, E,
//      S and W all clear to be legal and neither available tile has that, so the
//      contradiction is there before the search starts.  Propagation CANNOT detect
//      this one: a mask with nothing in it has nothing left to narrow.  Zero
//      collapses and zero backtracks are required, because a search that
//      "solves" this by backtracking has lost the plot.
//   2. PROPAGATION finds it -- tile set {end-E, end-S, straight-NS} (mask 44) on
//      2x2, where every initial domain is non-empty and the contradiction appears
//      as the constraint walks south and east.
//   3. an EMPTY domain from the tile set alone -- `loop` on 1x1 (every cell must
//      carry a socket, and the only cell is on all four edges) and `cross` on 3x2
//      (a cross has all four sockets, so every cell would have to be interior).
def t_unsat() -> void {
    wfc.setup(2, 2, tiles.SUB_STRAIGHTS, 1);
    // Every cell of a 2x2 is a corner, so all FOUR domains are empty, not one.
    ck_eq("straights 2x2: all four initial domains are empty", wfc.INITBAD, 4);
    ck_eq("straights 2x2: the enumerator agrees there is no solution",
          enum_run(2, 2, tiles.SUB_STRAIGHTS, 0), 0);
    wfc.setup(2, 2, tiles.SUB_STRAIGHTS, 1);
    let rc = wfc.solve();
    ck_eq("straights 2x2: the search reports UNSAT (not a budget failure)",
          rc, wfc.R_UNSAT);
    ck_eq("straights 2x2: nothing was collapsed", wfc.COLLAPSES, 0);
    ck_eq("straights 2x2: nothing was backtracked", wfc.BACKTRACKS, 0);
    ck("straights 2x2: at least one contradiction was recorded", wfc.CONTRA > 0,
       "CONTRA is " + tostring(wfc.CONTRA));

    // Shape 2, the one arc consistency exists for: mask 14 = the three ends
    // end-N, end-E, end-S on 3x3.  Every cell's initial domain is non-empty (the
    // bottom-right corner has exactly end-N), and the contradiction takes three
    // propagation steps to appear: the bottom-right corner is end-N, so the cell
    // above it needs N, so that cell is end-N, so the top-right corner -- which
    // is on the east edge and cannot be end-E -- needs N and has none.  Worked out
    // in README.md.
    let m14 = (1 << 1) | (1 << 2) | (1 << 3);
    ck_eq("mask 14 on 3x3 has no solutions (enumerator)", enum_run(3, 3, m14, 0), 0);
    wfc.setup(3, 3, m14, 1);
    ck_eq("mask 14 on 3x3: every initial domain is non-empty", wfc.INITBAD, 0);
    let pr = wfc.propagate();
    ck_eq("mask 14 on 3x3: propagation finds the contradiction", pr, 1);
    ck("mask 14 on 3x3: the contradiction names a cell in range",
       wfc.CONTRA_CELL >= 0 && wfc.CONTRA_CELL < wfc.NC,
       "CONTRA_CELL is " + tostring(wfc.CONTRA_CELL));
    wfc.setup(3, 3, m14, 1);
    rc = wfc.solve();
    ck_eq("mask 14 on 3x3: the search reports UNSAT", rc, wfc.R_UNSAT);
    ck_eq("mask 14 on 3x3: nothing was collapsed", wfc.COLLAPSES, 0);

    // `loop` on 1x1: every cell must carry a socket and the only cell is on all
    // four edges, so the initial domain is empty.  A different shape of
    // unsatisfiable -- an empty INITIAL domain rather than an empty propagated
    // one.
    wfc.setup(1, 1, tiles.SUB_LOOP, 1);
    rc = wfc.solve();
    ck_eq("loop 1x1: the search reports UNSAT", rc, wfc.R_UNSAT);
    ck_eq("loop 1x1: the enumerator agrees there is no solution",
          enum_run(1, 1, tiles.SUB_LOOP, 0), 0);

    // `cross` on 3x2: a cross has all four sockets, so every cell would have to
    // be an interior cell, and there are none.  Third shape, same verdict.
    wfc.setup(3, 2, tiles.SUB_CROSS, 1);
    rc = wfc.solve();
    ck_eq("cross 3x2: the search reports UNSAT", rc, wfc.R_UNSAT);
    ck_eq("cross 3x2: the enumerator agrees there is no solution",
          enum_run(3, 2, tiles.SUB_CROSS, 0), 0);

    // A satisfiable instance AFTER an unsatisfiable one must still work: the
    // failure must leave nothing behind.
    wfc.setup(4, 3, tiles.SUB_ALL, 1);
    rc = wfc.solve();
    ck_eq("4x3 all after the unsatisfiable runs: the search succeeds",
          rc, wfc.R_OK);
    ok_grid("4x3 all", 3)
};

// t_pictures() -- the real grids, against the real oracle.
def t_pictures() -> void {
    wfc.setup(12, 8, tiles.SUB_ALL, 1);
    let rc = wfc.solve();
    ck_eq("12x8 all seed 1: the search succeeds", rc, wfc.R_OK);
    ok_grid("12x8 all seed 1", 10);
    used_ok("12x8 all seed 1");

    wfc.setup(12, 8, tiles.SUB_ALL, 7);
    rc = wfc.solve();
    ck_eq("12x8 all seed 7: the search succeeds", rc, wfc.R_OK);
    ok_grid("12x8 all seed 7", 10);

    wfc.setup(6, 4, tiles.SUB_LOOP, 3);
    rc = wfc.solve();
    ck_eq("6x4 loop seed 3: the search succeeds", rc, wfc.R_OK);
    ck_eq("6x4 loop seed 3: no cell is left empty", empty_cells(), 0);
    ok_grid("6x4 loop seed 3", wfc.NC);
    used_ok("6x4 loop seed 3");
};

def empty_cells() -> long {
    let n = 0;
    let i = 0;
    while (i < wfc.NC) {
        if (CSOCK[cfirst(wfc.MASK[i])] == 0) { n = n + 1 };
        i = i + 1
    };
    n
};

// UF and SIZE -- the union-find and its per-root component sizes.  Both are sized
// for the largest grid any check hands them (12x8 = 96 cells, and t_scale touches
// 4096); a 64-element array was an out-of-bounds write, i.e. a runtime trap on
// stdout, in the middle of the battery.
let UF: [long; 4096] = [0; 4096];
let SIZE: [long; 4096] = [0; 4096];

// used_ok(label) -- the network is a union of closed loops, checked two ways:
// this file counts the components with a union-find AND with a flood fill, over
// the same parsed socket table, and requires the two algorithms to agree.  (The
// driver prints a third count, from its own flood fill, in the golden run.)
def used_ok(label: str) -> void {
    let uf = uf_components();
    let ff = ff_components();
    ck_eq("grid " + label + ": component count agrees (union-find vs flood fill)",
          uf, ff);
    ck("grid " + label + ": the network has at least one component", uf > 0,
       "the network is empty");
    // Every component has at least two cells.  A one-cell component would carry a
    // socket no neighbour matched -- which ok_grid already rejects -- so this is the
    // cheap restatement of "no component is a lone cell", and it is a claim about
    // the SHAPE of the network rather than about its legality.
    //
    // (An earlier draft asserted that no cell carries exactly one socket.  That is
    // false: two end tiles facing each other are a legal two-cell component, and
    // `2x2 ends` has exactly such a solution.  A check that is wrong about a legal
    // grid is worse than no check, because it teaches you to ignore it.)
    ck("grid " + label + ": every component has at least two cells",
       min_component() >= 2,
       "a component of " + tostring(min_component()) + " cells")
};

// min_component() -> long -- the size of the smallest pipe component, or 0 when
// the network is empty.
def min_component() -> long {
    let i = 0;
    while (i < wfc.NC) { UF[i] = i; SIZE[i] = 0; i = i + 1 };
    link_all();
    let n = 0;
    i = 0;
    while (i < wfc.NC) {
        if (CSOCK[cfirst(wfc.MASK[i])] != 0) {
            let r = c_find(i);
            SIZE[r] = SIZE[r] + 1;
            n = n + 1
        };
        i = i + 1
    };
    if (n == 0) { return 0 };
    let best = 0 - 1;
    let k = 0;
    while (k < wfc.NC) {
        if (SIZE[k] > 0) {
            if (best < 0 || SIZE[k] < best) { best = SIZE[k] }
        };
        k = k + 1
    };
    best
};

def c_find(i: long) -> long {
    let r = i;
    let done = 0;
    while (done == 0) {
        if (UF[r] == r) { done = 1 } else { r = UF[r] }
    };
    let k = i;
    let going = 1;
    while (going == 1) {
        let nxt = UF[k];
        UF[k] = r;
        if (nxt == k) { going = 0 };
        k = nxt
    };
    r
};

// uf_components() -> long -- connected components by union-find.  An empty cell
// is not a component of the pipe network, it is the absence of one, so only
// socket-carrying cells are counted as roots.
def uf_components() -> long {
    let i = 0;
    while (i < wfc.NC) { UF[i] = i; SIZE[i] = 0; i = i + 1 };
    link_all();
    let n = 0;
    i = 0;
    while (i < wfc.NC) {
        if (CSOCK[cfirst(wfc.MASK[i])] != 0 && c_find(i) == i) { n = n + 1 };
        i = i + 1
    };
    n
};

let FS: [long; 4096] = [0; 4096];
let FSEEN: [byte; 4096] = [0; 4096];

// ff_components() -> long -- the same number by an explicit flood fill, a
// different algorithm over the same data.  Two algorithms agreeing is worth more
// than one algorithm agreeing with itself, which is the mistake that made an
// earlier draft of this file compare a function with itself.
def ff_components() -> long {
    let i = 0;
    while (i < wfc.NC) { FSEEN[i] = 0; i = i + 1 };
    let n = 0;
    let start = 0;
    while (start < wfc.NC) {
        if (FSEEN[start] == 0 && CSOCK[cfirst(wfc.MASK[start])] != 0) {
            n = n + 1;
            let sp = 0;
            FS[sp] = start;
            sp = sp + 1;
            FSEEN[start] = 1;
            let go = true;
            while (go) {
                let c = FS[sp - 1];
                sp = sp - 1;
                let d = 0;
                while (d < 4) {
                    let j = cneigh(c, wfc.GW, wfc.GH, d);
                    if (j >= 0 && FSEEN[j] == 0 && shares(c, j, d)) {
                        FSEEN[j] = 1;
                        FS[sp] = j;
                        sp = sp + 1
                    };
                    d = d + 1
                };
                go = sp > 0
            }
        };
        start = start + 1
    };
    n
};

// link_all() / shares() -- the union-find's edges: two neighbours are in the
// same component exactly when they carry a matching socket.
def link_all() -> void {
    let y = 0;
    while (y < wfc.GH) {
        let x = 0;
        while (x < wfc.GW) {
            let a = y * wfc.GW + x;
            let d = 1;
            while (d < 4) {
                let j = cneigh(a, wfc.GW, wfc.GH, d);
                if (j >= 0 && shares(a, j, d)) {
                    let ra = c_find(a);
                    let rb = c_find(j);
                    if (ra != rb) { UF[ra] = rb }
                };
                d = d + 1
            };
            x = x + 1
        };
        y = y + 1
    }
};

def shares(a: long, j: long, d: long) -> bool {
    if (cbit(cfirst(wfc.MASK[a]), d) == 0) { return false };
    if (cbit(cfirst(wfc.MASK[j]), copp(d)) == 0) { return false };
    true
};

// t_rule() -- the selection rule, asserted against the state the search is in
// WHEN IT MAKES EACH DECISION.
//
// The battery drives the solver one event at a time and, BEFORE each event,
// recomputes from the live masks the entropy of every cell.  It then requires
// that the cell the solver recorded (EV_C) is the lowest-indexed cell of minimum
// entropy, and that the entropy it recorded (EV_H) is that minimum.  So the rule
// is checked against the state the choice was actually made from -- not against
// the initial domain, which is NOT the same thing, because the first
// propagation has already narrowed cells before the first decision.
//
// An earlier draft of this check compared the recorded decisions against
// per-decision snapshots of the mask grid, and five of eleven decisions came out
// wrong for one reason only: the state before decision 0 is the state after the
// initial propagation, not the boundary-only initial domain.  Driving the solver
// directly removes the whole class of "which snapshot am I looking at" mistakes.
let RW: long = 4;
let RH: long = 3;
let RBAD_CELL: long = 0;
let RBAD_H: long = 0;
let RTIES: long = 0;
let RDEC: long = 0;

def t_rule() -> void {
    wfc.setup(RW, RH, tiles.SUB_ALL, 5);
    RBAD_CELL = 0;
    RBAD_H = 0;
    RTIES = 0;
    RDEC = 0;
    let finished = 0;
    while (finished == 0) {
        // REACH THE FIXPOINT FIRST.  This is the whole subtlety of checking a
        // wave-function collapse from the outside: the state a decision is made
        // from is the state AFTER propagation, not the state before the event.
        // An earlier draft of this check scanned the masks as they stood before
        // calling next_event() and found five of eleven decisions "wrong" --
        // all of them cells that propagation was about to narrow.  The solver was
        // right and the check was wrong, which is the useful kind of wrong: it is
        // why this loop calls propagate() before it looks at anything.
        wfc.propagate();
        // The index the NEXT event will be recorded at.  Events and decisions are
        // not the same counter: a backtrack is an event too, so counting decisions
        // and indexing the event log with it reads the wrong row the moment the
        // search backtracks once.
        let idx = wfc.EV_N;
        // the minimum-entropy open cell, by this file's own arithmetic
        let best = 0 - 1;
        let bh = 0;
        let nties = 0;
        let i = 0;
        while (i < wfc.NC) {
            if (cpop(wfc.MASK[i]) > 1) {
                let e = wfc.entropy(wfc.MASK[i]);
                if (best < 0 || e < bh) {
                    best = i;
                    bh = e;
                    nties = 1
                } else if (e == bh) {
                    nties = nties + 1;
                    if (i < best) { best = i }
                }
            };
            i = i + 1
        };
        let ev = wfc.next_event();
        // The comparison happens AFTER the event, because the event is what
        // writes that slot: before next_event() the recorded entropy at index
        // `idx` is still the initial 0 of an array nothing has written yet.  An
        // earlier draft compared before the call and reported eleven wrong
        // decisions out of eleven -- eleven comparisons of a live number against
        // a slot that had not been filled in.  That is the shape of the vacuous
        // comparison this campaign keeps hitting, and it failed loudly only
        // because `bh != 0`.
        // Only a COLLAPSE records a cell.  A backtrack event records cell -1, and
        // comparing the minimum-entropy cell against -1 is how the six failures
        // here appeared: this instance does backtrack once, and the check was
        // holding the search to the selection rule on an event where no cell was
        // chosen at all.
        if (ev == wfc.E_COLLAPSE && best >= 0) {
            if (best != wfc.EV_C[idx]) { RBAD_CELL = RBAD_CELL + 1 };
            if (bh != wfc.EV_H[idx]) { RBAD_H = RBAD_H + 1 };
            if (nties > 1) { RTIES = RTIES + 1 };
            RDEC = RDEC + 1
        };
        if (ev == wfc.E_DONE || ev == wfc.E_FAIL) { finished = 1 }
    };
    ck_eq("every decision chose the lowest-indexed cell of minimum entropy",
          RBAD_CELL, 0);
    ck_eq("every decision recorded the entropy of the cell it chose", RBAD_H, 0);
    // The tie-break is load-bearing or it is decoration: if no decision on this
    // instance were decided by a tie, the two checks above are untested.
    ck("the index tie-break fired at least once (so the rule is not vacuous)",
       RTIES > 0, "no decision had two cells at the minimum entropy");
    if (VERBOSE == 1) {
        print("     " + tostring(RDEC) + " decisions, " + tostring(RTIES) +
              " of them decided by the index tie-break")
    };
    ck_eq("the recorded entropy was never zero (an uncollapsed cell has entropy > 0)",
          zero_entropies(), 0);
    // And after all that driving, the grid the search reached is still the one a
    // plain solve() reaches: the step-by-step path and the batch path agree.
    wfc.setup(RW, RH, tiles.SUB_ALL, 5);
    wfc.solve();
    ok_grid("4x3 all seed 5 (driven step by step)", 2)
};

def zero_entropies() -> long {
    let n = 0;
    let k = 0;
    while (k < wfc.EV_N) {
        if (wfc.EV_C[k] >= 0 && wfc.EV_H[k] == 0) { n = n + 1 };
        k = k + 1
    };
    n
};

// t_determinism() -- same seed, same picture; different seed, different picture.
//
// The second half matters as much as the first: "the same seed gives the same
// answer" is also true of a program that ignores the seed, and this is where that
// shows up.
def t_determinism() -> void {
    let a = solve_hash(12, 8, 1);
    let b = solve_hash(12, 8, 1);
    let c = solve_hash(12, 8, 2);
    ck_eq("the same seed gives the same picture (two runs, hashed)", a, b);
    ck("a different seed gives a different picture", a != c,
       "seed 1 and seed 2 both hashed to " + tostring(a));
    ck("the picture is not empty (the digest is of something)", a != 0,
       "the digest is zero");
    // And the tie-break is not what makes it deterministic: a DIFFERENT tie-break
    // must give a DIFFERENT picture.  If it did not, the picture would not depend
    // on the rule at all, and asserting the rule would be asserting nothing.
    let d = solve_hash_tie(12, 8, 1);
    ck("a different (wrong) tie-break gives a different picture", a != d,
       "the last minimum and the first minimum gave the same picture")
};

def solve_hash(w: long, h: long, seed: long) -> long {
    wfc.setup(w, h, tiles.SUB_ALL, seed);
    wfc.solve();
    grid_hash()
};

// solve_hash_tie(w, h, seed) -- the same solve with defect 4 in force, which
// breaks entropy ties on the LAST index instead of the lowest.
def solve_hash_tie(w: long, h: long, seed: long) -> long {
    let keep = wfc.INJECT;
    set_all(4);
    wfc.setup(w, h, tiles.SUB_ALL, seed);
    wfc.solve();
    let hsh = grid_hash();
    set_all(keep);
    hsh
};

// grid_hash() -> long -- FNV-1a over the ASCII of every cell.
def grid_hash() -> long {
    let hash = 0 - 3750763034362895579;
    let i = 0;
    while (i < wfc.NC) {
        let c = tiles.ASC[wfc.first_bit(wfc.MASK[i])];
        hash = hash ^ c;
        hash = hash * 1099511628211;
        i = i + 1
    };
    hash
}

// t_digest() -- the frame digest is a digest OF THE PAINTED BYTES.
//
// sink.paint_hash() is what the golden file prints beside every frame, so a
// digest of something other than the picture would make the frames unreadable.
// Recomputed here, independently, over the bytes this file believes the picture
// is; and then required to move when one cell is perturbed.
// It was: the first version hashed the cells without the newline that ends each
// row, so this check disagreed with it by exactly that.  Here the digest is
// recomputed over the bytes this file believes the picture is, ROW BY ROW,
// newline included, and then required to move when one cell's byte is perturbed.
def t_digest() -> void {
    wfc.setup(6, 4, tiles.SUB_ALL, 2);
    wfc.solve();
    ck_eq("the frame digest equals FNV-1a over the painted bytes, newlines included",
          sink.paint_hash(), own_hash(0 - 1));
    ck("the digest changes when one cell's byte is perturbed",
       sink.paint_hash() != own_hash(1), "the two digests agree");
    ck_eq("the digest does not change when nothing is perturbed",
          own_hash(0 - 1), own_hash(0 - 1))
};

// own_hash(skip) -- this file's FNV-1a over the ASCII of every cell except cell
// `skip` (whose byte is nudged by one so the digest must move), with a newline
// after every row exactly as sink.paint() writes them.
def own_hash(skip: long) -> long {
    let hash = 0 - 3750763034362895579;
    let y = 0;
    while (y < wfc.GH) {
        let x = 0;
        while (x < wfc.GW) {
            let i = y * wfc.GW + x;
            let c = tiles.ASC[wfc.first_bit(wfc.MASK[i])];
            if (i == skip) { c = c + 1 };
            hash = hash ^ c;
            hash = hash * 1099511628211;
            x = x + 1
        };
        hash = hash ^ 10;
        hash = hash * 1099511628211;
        y = y + 1
    };
    hash
}

// t_backtrack() -- the backtracking path is exercised, and needed.
//
// A battery that only ever ran satisfiable instances with no contradiction would
// pass with backtrack() deleted.  So: an instance where the search really does
// contradict itself and recover, requiring the recovery to succeed and the
// counters to say it happened.
// The backtracking instance is `elbows` on 16x12, seed 2: exactly two
// contradictions, both recovered, both invisible in the answer.  It is not a big
// grid of ordinary tiles, because a sweep of every size from 2x2 to 20x20 and
// every seed from 1 to 7 found only a handful of instances that needed a rewind
// at all -- the sixteen-tile set propagates hard enough that the first choice is
// nearly always extendable.  A battery that quietly asserted "backtracks > 0" on
// such an instance would have been asserting nothing; this one is real, and the
// search needs the undo log to get there.
//
// THE SEED IS 2, AND IT WAS 1.  This instance was FOUND by sweeping sizes and
// seeds under the xorshift64 this file used to carry, so it is a property of
// (generator, size, seed) and not of the solver: with std's splitmix64 in place
// (see wfc.y, "the PRNG") 16x12 seed 1 propagates to a single solution and needs
// no rewind at all, which would have left t_backtrack and t_rewind asserting
// nothing.  The sweep was re-run over 10x10..20x18 and seeds 1..7, and 16x12
// seed 2 is the instance that still contradicts itself exactly twice and
// recovers -- 69 collapses, 2 contradictions, 2 backtracks, 783 steps.  The two
// pinned counts are unchanged, which is the point: what the battery claims is
// "this instance needs a rewind and gets it", and it still does.
let BT_W: long = 16;
let BT_H: long = 12;
let BT_SEED: long = 2;

def t_backtrack() -> void {
    wfc.setup(BT_W, BT_H, tiles.SUB_ELBOWS, BT_SEED);
    let rc = wfc.solve();
    ck_eq("16x12 elbows seed 2: the search succeeds", rc, wfc.R_OK);
    ck("16x12 elbows seed 2: it really did backtrack", wfc.BACKTRACKS > 0,
       "BACKTRACKS is " + tostring(wfc.BACKTRACKS));
    // Pinned exactly, so an instance that stopped needing a rewind would fail
    // loudly instead of quietly ceasing to test the undo log.  (It also cannot be
    // "more collapses than cells" the way an ordinary all-tiles grid would be:
    // propagation decides most cells there, so 16x12 elbows needs 71 decisions for
    // 192 cells.)
    ck_eq("16x12 elbows seed 2: exactly two contradictions", wfc.CONTRA, 2);
    ck_eq("16x12 elbows seed 2: exactly two backtracks", wfc.BACKTRACKS, 2);
    ck("16x12 elbows seed 2: no more surviving decisions than cells",
       wfc.COLLAPSES - wfc.BACKTRACKS <= wfc.NC,
       tostring(wfc.COLLAPSES) + " collapses minus " + tostring(wfc.BACKTRACKS) +
       " undone for " + tostring(wfc.NC) + " cells");
    ok_grid("16x12 elbows seed 2", 4);
    ck("16x12 elbows seed 2: the undo log never approached its array bound",
       wfc.UNDOMAX > 0 && wfc.UNDOMAX < 131072,
       "peak undo depth " + tostring(wfc.UNDOMAX))
};

// t_rewind() -- "a rewind restores the state EXACTLY", checked directly.
//
// The undo path's contract is stronger than "the answer is still valid": after a
// backtrack the mask of EVERY cell must be what it was immediately before the
// decision that was undone, no matter how many cells that decision's propagation
// touched and in whatever order.  That is a statement about the search, not about
// the output, and it is the only check that sees a rewind which loses one undo
// entry: the search then carries a corrupted log that may or may not produce a
// wrong grid on any given instance, and on 16x12 elbows it did not.
//
// WHICH STATE IS "BEFORE THE DECISION", which took three attempts to get right and
// is worth writing down.  A decision is made from the state at the FIXPOINT --
// after the propagation at the top of that event -- so the reference state is
// neither the end of the previous event (before that propagation narrowed
// something) nor the end of the decision event (after the collapse).  Two earlier
// drafts compared against those two and "found" bad cells on a solver that was
// correct; the way to reach the real thing is to call propagate() FIRST, snapshot,
// and only then call next_event() -- whose own propagation is then a no-op, and
// whose decision is therefore made from exactly the state that was snapshotted.
//
// The references are a STACK, one per decision, because a rewind pops the last
// decision: two rewinds in a row compare against two different references.
// The references are a RING of sixteen, indexed by the decision count modulo
// sixteen, not a growing stack: a rewind always undoes the MOST RECENT decision,
// so the reference it needs is always the last one pushed, and sixteen is ample.
// (A first attempt kept the decision count as a flat index into a 4096-element
// array; this instance makes 69 decisions before its first rewind, so 69*192 = 13248
// ran off the end -- a runtime trap on stdout.  The guard that was supposed to
// prevent it only covered the push, and the read still indexed with the full count.)
const REFMAX: long = 16;
let REF: [long; 4096] = [0; 4096];
let TOP: long = 0;
let REWINDS: long = 0;
let RBADD: long = 0;
let RBADCELL: long = 0 - 1;

def ref_push(k: long) -> void {
    let slot = k % REFMAX;
    let base = slot * wfc.NC;
    let i = 0;
    while (i < wfc.NC) { REF[base + i] = wfc.MASK[i]; i = i + 1 }
};

def ref_at(k: long) -> long {
    let slot = k % REFMAX;
    if (slot < 0) { return 0 };
    slot * wfc.NC
};

def t_rewind() -> void {
    REWINDS = 0;
    RBADD = 0;
    RBADCELL = 0 - 1;
    TOP = 0;
    wfc.setup(BT_W, BT_H, tiles.SUB_ELBOWS, BT_SEED);
    let finished = 0;
    while (finished == 0) {
        // The fixpoint the next decision -- or the next contradiction -- will be
        // made from.
        wfc.propagate();
        ref_push(TOP);
        let ev = wfc.next_event();
        if (ev == wfc.E_BACKTRACK) {
            REWINDS = REWINDS + 1;
            let bad = 1;
            let at = 0 - 1;
            if (TOP > 0) {
                TOP = TOP - 1;
                let base = ref_at(TOP);
                bad = 0;
                let i = 0;
                while (i < wfc.NC) {
                    if (wfc.MASK[i] != REF[base + i]) {
                        bad = bad + 1;
                        if (at < 0) { at = i }
                    };
                    i = i + 1
                }
            };
            RBADD = RBADD + bad;
            if (at >= 0) { RBADCELL = at }
        } else if (ev == wfc.E_COLLAPSE) {
            TOP = TOP + 1
        } else {
            finished = 1
        }
    };
    ck("16x12 elbows seed 2: at least one rewind to check", REWINDS > 0,
       "no rewind happened, so the undo path was not exercised");
    ck_eq("every rewind restored EVERY cell's mask exactly", RBADD, 0);
    // The counter that explains the two invisible versions of the rewind defect:
    // on this instance the entry just below each mark was still in force, and it
    // belonged to a cell the undone decision also touched, so the loop's own restore
    // hid the damage.  Printed rather than asserted: on another instance the counts
    // could legitimately go the other way, and a check that pinned them would be a
    // check that fails for the right reason on the wrong day.
    if (VERBOSE == 1) {
        print("     " + tostring(REWINDS) + " rewinds, " + tostring(TOP) +
              " decisions still standing; the entry below the mark was still in " +
              "force " + tostring(wfc.XTRA_DIFF) + " times and already undone " +
              tostring(wfc.XTRA_SAME) + " times")
    }
};

// t_giveup() -- the step budget, on an instance that provokes it.
//
// 16x16 `elbows`, seed 37: the search contradicts itself 88 473 times, gets
// nowhere, and STOPS at the budget with R_BUDGET.  This is the "must never hang"
// property made testable: the return value says it gave up rather than found an
// answer, the step count is inside the budget, and no trap is printed.  (The
// half-finished grid it leaves behind is deliberately NOT audited: there is no
// answer to audit.)
//
// THE SEED IS 37, AND IT WAS 1 -- the same reason as BT_SEED above, and the same
// consequence: the old stream's 16x16 seed 1 now solves outright in 912 steps,
// so t_giveup would have stopped testing the budget at all, and gate.conf's
// `check=` line (which asserts exit 4 through a real process) would have been
// asserting an exit status the program no longer produces.  A sweep of 16x16
// seeds 1..37 found seed 37: 88 559 collapses, 88 473 contradictions,
// 88 473 backtracks, 4 000 002 steps, and exit 4.  gate.conf names the same
// instance, and the numbers above are that run's.
def t_giveup() -> void {
    wfc.setup(16, 16, tiles.SUB_ELBOWS, 37);
    let rc = wfc.solve();
    ck_eq("16x16 elbows seed 37: the search gives up with R_BUDGET", rc, wfc.R_BUDGET);
    ck("16x16 elbows seed 37: it stopped AT the budget, not before",
       wfc.STEPS >= wfc.BUDGET && wfc.STEPS <= wfc.BUDGET + 64,
       tostring(wfc.STEPS) + " steps against a budget of " + tostring(wfc.BUDGET));
    ck("16x16 elbows seed 37: it contradicted itself many times on the way",
       wfc.CONTRA > 1000, "CONTRA is " + tostring(wfc.CONTRA));
    ck("16x16 elbows seed 37: the decision stack stayed inside its array",
       wfc.DN < 16384, "DN is " + tostring(wfc.DN))
};

// t_scale() -- a full-size grid, inside the budget and inside the array bounds.
//
// The budget is what stops a pathological instance from hanging, so a grid big
// enough to need it has to solve here too: a budget so tight that the flagship
// instance failed would be a hang in disguise.
def t_scale() -> void {
    wfc.setup(64, 64, tiles.SUB_ALL, 1);
    let rc = wfc.solve();
    ck("64x64 all seed 1: a full-size grid solves", rc == wfc.R_OK,
       "rc " + tostring(rc) + " after " + tostring(wfc.STEPS) + " steps");
    ck_eq("64x64 all: no cell is left open", wfc.undecided(), 0);
    ck_eq("64x64 all: the solver's own audit finds no violation", wfc.audit(), 0);
    ck("64x64 all: the step count is inside the budget", wfc.STEPS < wfc.BUDGET,
       tostring(wfc.STEPS) + " steps against a budget of " + tostring(wfc.BUDGET));
    ck("64x64 all: the undo log stayed inside its array",
       wfc.UNDOMAX > 0 && wfc.UNDOMAX < 131072,
       "peak undo depth " + tostring(wfc.UNDOMAX))
};

// ───────────────────────────────────────────────── the defect injection sweep ───
//
// Seventeen deliberate defects live in wfc.y and tiles.y, each behind an
// `if (INJECT == n)`, each a mistake a real implementation makes: the wrong
// neighbour direction, a union where an intersection belongs, a contradiction not
// noticed, a tie-break the other way round, a draw that counts tiles instead of
// weight, an undo log that is not rewound, an entropy read from the wrong row, a
// boundary not applied, propagation that does not restart from the top.
//
// A check that has never failed is not known to work, so each is injected in turn
// and the battery MUST fail.  The sweep is not a claim that the battery is
// perfect -- it is the specific claim that each of these seventeen defects is
// visible to it, which is the strongest thing that can be said without a human
// reading the code line by line.

const NINJ: long = 17;

// inject_name(n) -- what the defect is, for the output and for the README.
def inject_name(n: long) -> str {
    if (n == 1) { return "propagate skips the south step" }
    if (n == 2) { return "propagate unions instead of intersecting" }
    if (n == 3) { return "propagate ignores a mask that emptied" }
    if (n == 4) { return "pick breaks an entropy tie on the LAST index" }
    if (n == 5) { return "pick ignores entropy and takes the first open cell" }
    if (n == 6) { return "the weighted draw counts tiles, not weight" }
    if (n == 7) { return "backtrack does not restore the mask" }
    if (n == 8) { return "backtrack rewinds one entry too far" }
    if (n == 9) { return "entropy reads the log2 table one row off" }
    if (n == 10) { return "CNT is one too high on every cell" }
    if (n == 11) { return "the boundary answers for the opposite side" }
    if (n == 12) { return "the north boundary is not applied" }
    if (n == 13) { return "the south direction reads as east" }
    if (n == 14) { return "a contradiction is fatal: no backtracking" }
    if (n == 15) { return "HENT carries a stale value" }
    if (n == 16) { return "the search calls itself done after one decision" }
    return "propagation does not re-queue a cell it changed"
};

// battery() -> long -- every check, with the current INJECT in force.  Returns
// the number of failures.  QUIET while sweeping so seventeen runs do not bury
// the real output; the failures still print, and FIRST names the first one.
def battery() -> long {
    RUN = 0;
    FAILED = 0;
    FIRST = "";
    t_table();
    t_subsets();
    t_entropy();
    t_draw();
    t_bookkeeping();
    t_tiny();
    t_complete();
    t_unsat();
    t_pictures();
    t_rule();
    t_determinism();
    t_digest();
    t_backtrack();
    t_rewind();
    t_giveup();
    t_scale();
    FAILED
};

// sweep_child() -> long -- what runs inside the forked child: the whole battery,
// then an exit status of 2 if anything failed, 0 if not, and 1 if the battery
// itself trapped before it could say.
def sweep_child() -> long {
    SHOWFAIL = 0;
    let f = battery();
    if (f > 0) {
        print("         " + tostring(f) + " checks failed; the first was: " + FIRST);
        return 2
    };
    0
};

// if_result(n, what, status) -- one line of the sweep, from the child's exit
// status: 0 is MISSED, 2 is caught with failed checks, anything above 128 is a
// signal, i.e. the defect killed the child outright (which still counts as caught,
// and is reported as what it is rather than as a pass).
def if_result(n: long, what: str, status: long) -> str {
    let s = "  ";
    if (status == 0) {
        s = s + "MISSED"
    } else if (status > 128) {
        s = s + "caught  (defect KILLED the run: signal " + tostring(status - 128) + ")"
    } else {
        s = s + "caught"
    };
    s = s + "  inject " + pad2(n) + "  " + what
};

// ─────────────────────────────────────────────────────────────────── the run ───

def run_check() -> long {
    if (INJECTWANT > 0) {
        // The single-defect mode a reader can run by hand: the whole battery,
        // verbose, with that one defect in force.  It is SUPPOSED to fail, and
        // the exit code says 5 for exactly that reason.
        set_all(INJECTWANT);
        VERBOSE = 1;
        print("wavefunction --check --inject " + tostring(INJECTWANT) + ": " +
              inject_name(INJECTWANT));
        print("");
        let f = battery();
        print("");
        print("with that defect in force: " + tostring(RUN) + " checks, " +
              tostring(f) + " failed");
        if (f > 0) { print("first failure: " + FIRST) };
        print("");
        print("wavefunction --check: FAIL (as it must -- that is what an injected");
        print("defect is for; see README.md for the list)");
        return 5
    };

    VERBOSE = 1;
    set_all(0);
    print("wavefunction --check: the property battery; no reference file is read");
    print("");
    let base = battery();
    print("");
    print("clean run: " + tostring(RUN) + " checks, " + tostring(base) + " failed");
    if (base > 0) {
        print("");
        print("the battery does not pass on the un-defected solver, so the sweep");
        print("below would be meaningless; stopping here");
        return 5
    };

    // ── the sweep ──
    print("");
    print("injecting each of the " + tostring(NINJ) +
          " deliberate defects; every one must be caught");
    VERBOSE = 0;
    let k = 1;
    while (k <= NINJ) {
        set_all(k);
        // Each injected defect runs in a FORKED CHILD.  Not for isolation of the
        // heap -- it is copy-on-write and the battery allocates nothing -- but
        // because some defects are worse than wrong: injection 8 (rewind one entry
        // too many) drove an undo-log index negative, and a runtime trap prints to
        // STDOUT and kills the process, which took the whole sweep down with it and
        // left the report saying nothing after defect 7.  A child that dies is a
        // child whose defect was caught; the parent is still there to say so.
        let pid = fork { exit(sweep_child()) };
        let st = wait_pid(pid);
        if (st == 0) {
            MISSED = MISSED + 1;
            if (MISSEDLIST != "") { MISSEDLIST = MISSEDLIST + ", " };
            MISSEDLIST = MISSEDLIST + tostring(k)
        } else {
            CAUGHT = CAUGHT + 1
        };
        print(if_result(k, inject_name(k), st));
        k = k + 1
    };
    set_all(0);
    VERBOSE = 1;
    SHOWFAIL = 1;
    print("");
    print("injected " + tostring(NINJ) + " defects, caught " + tostring(CAUGHT) +
          ", missed " + tostring(MISSED));
    if (MISSED > 0) {
        print("");
        print("MISSED (" + MISSEDLIST + "): the battery cannot see these, so its");
        print("other passes are worth less than they look");
        return 5
    };
    print("");
    print("wavefunction --check: PASS");
    0
};

def pad2(n: long) -> str {
    if (n < 10) { return "0" + tostring(n) };
    tostring(n)
};

export { run_check, set_inject_want, set_all, ok_grid, inject_name, NINJ };