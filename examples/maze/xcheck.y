// xcheck.y -- the strongest check in this folder, made runnable.
//
// It answers one question about `astar.y` that the length cross-check cannot:
// is A* actually expanding the set of cells it is supposed to?
//
// THE ARGUMENT.  A perfect maze is a TREE, so there is exactly one path from the
// start to any cell c.  Along that path g rises by 1 per step and h changes by
// at most 1 per step, so f = g + h never decreases on the way: every cell on the
// path to c has f <= f(c).  Therefore, if f(c) <= L (the optimum), every cell
// on c's path also has f <= L and is expanded before the goal is popped -- which
// means c is discovered and expanded too.  So A* must expand EXACTLY
//
//     { c : g(c) + h(c) <= L }
//
// where g comes from BFS.  That set is countable in one linear scan of the
// distance array, with no reference at all to the heap, the sift, the tie-break
// or the lazy-deletion skip.  If A*'s expansion count differs from it, the
// search is wrong -- and the length alone would not have shown it, because on a
// tree there is only one possible route to check.
//
//   build:  ycc -o xcheck xcheck.y
//   run:    ./xcheck          prints a table; exit 1 on any mismatch
//
// Deterministic: fixed sizes, fixed seeds, integer arithmetic, no timing.

import grid;
import astar;
import sink;

let SIZES: [long; 4] = [3, 39, 101, 201];
let NSEED: long = 6;

// FAILS -- the running total of disagreements.  Every check above adds to it and
// main() exits 1 on it, so this tool is a gate step and not just a report.
let FAILS: long = 0;

// predict(goal, L) -> long -- how many cells A* is obliged to expand, counted
// from BFS's own g values and nothing else.
def predict(goal: long, L: long) -> long {
    let n = 0;
    let i = 0;
    while (i < grid.NCE) {
        let g = astar.sdist[i];
        // g >= 0 is "reachable at all"; the maze is a tree so every cell is.
        if (g >= 0 && g <= L && g + astar.heur(i, goal) <= L) { n = n + 1; };
        i = i + 1
    };
    n
};

def emit(sz: long, gi: long, diffseeds: long, saved: long, mism: long) -> void {
    FAILS = FAILS + mism;
    sink.sink_str("  ");
    sink.sink_pad(sz, 4);
    sink.sink_str("x");
    sink.sink_pad(sz, 4);
    sink.sink_str("  ");
    sink.sink_padl(grid.GENS[gi], 9);
    sink.sink_str(" A* smaller on ");
    sink.sink_pad(diffseeds, 2);
    sink.sink_str("/");
    sink.sink_num(NSEED);
    sink.sink_str("  cells saved ");
    sink.sink_pad(saved, 7);
    sink.sink_str("   wrong expansion set on ");
    sink.sink_pad(mism, 2);
    sink.sink_str("/");
    sink.sink_num(NSEED);
    sink.sink_nl()
};

def row() -> void {
    let si = 0;
    while (si < 4) {
        let sz = SIZES[si];
        grid.grid_setup(sz, sz);
        let goal = grid.NCE - 1;
        let gi = 0;
        while (gi < 3) {
            let nseed = 0;
            let diffseeds = 0;
            let saved = 0;
            let mism = 0;
            while (nseed < NSEED) {
                let seed = nseed + 1;
                if (gi == 0) { grid.gen_rb(seed); }
                else if (gi == 1) { grid.gen_prim(seed); }
                else { grid.gen_kruskal(seed); };
                let L = astar.bfs(0, goal);
                let nb = astar.pexp;
                let pred = predict(goal, L);
                let la = astar.astar(0, goal);
                let na = astar.pexp;
                // Three independent things to insist on.
                if (la != L) { mism = mism + 1; };
                if (pred != na) { mism = mism + 1; };
                if (astar.pok != 1) { mism = mism + 1; };
                if (nb != na) { diffseeds = diffseeds + 1; saved = saved + (nb - na) };
                nseed = nseed + 1
            };
            emit(sz, gi, diffseeds, saved, mism);
            gi = gi + 1
        };
        si = si + 1
    }
};

def main() -> void {
    sink.sink_str("xcheck: does A* expand exactly {c : g(c) + h(c) <= L}?\n");
    sink.sink_str("  4 sizes x 3 generators x ");
    sink.sink_num(NSEED);
    sink.sink_str(" seeds = ");
    sink.sink_num(4 * 3 * NSEED);
    sink.sink_str(" searches, each checked three ways\n");
    sink.sink_str("    A* smaller on = A* expanded strictly fewer cells than BFS\n");
    sink.sink_str("    wrong expansion set = A* length != BFS length, or A* expanded a\n");
    sink.sink_str("      number of cells no correct lazy-deletion A* could expand, or the\n");
    sink.sink_str("      route failed its wall-by-wall verification\n\n");
    row();
    sink.sink_str("\n  checks failed: ");
    sink.sink_num(FAILS);
    sink.sink_str("\n\n");
    sink.sink_flush();
    if (FAILS != 0) { exit(1) }
};

main();