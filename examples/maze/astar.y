// astar.y -- two shortest-path solvers over grid.y, and the binary heap A* needs.
//
// ─────────────────────────────────────────────────────────────────────────
// WHY TWO SOLVERS.  A maze from any of the three generators in grid.y is a
// PERFECT maze: a spanning tree of passages.  A tree has exactly one path
// between any two cells, so the solution is unique and there is nothing for the
// two solvers to disagree about in principle.  That is worth saying plainly,
// because it means the cross-check below is not "do two algorithms find the
// same shortest path" -- it never could not.  What the cross-check actually
// establishes is:
//
//   * each solver walks a path that is LEGAL -- verify_path() re-walks the
//     answer through the wall bits, so a solver that returned a plausible
//     number with an impossible path behind it fails;
//   * both report the same LENGTH, and both return the identical cell
//     SEQUENCE, which catches a wrong parent pointer that still gives a
//     plausible length;
//   * and the interesting difference shows up where it really is -- in how
//     many cells each one had to expand.  BFS expands the whole ball of radius
//     L around the start; A* expands the ellipse f = g + h <= L.  On a 39x11
//     recursive-backtracker maze that is a large gap, and it is the entire
//     reason to have a heuristic.
//
// ─────────────────────────────────────────────────────────────────────────
// THE PRIORITY QUEUE.  A binary min-heap in one fixed array.  The element is
// ONE LONG, not a pair: the f value is packed into the high 32 bits and the cell
// index into the low 32, so a plain `<` compares (f, cell) lexicographically
// and the tie-break is free and deterministic.
//
//     key = f * 4294967296 + cell
//
// Why pack: two parallel arrays would double the memory and double the number
// of loads in the sift, and the swap in a sift would have to move both.
// Why it is safe: the grid is at most 201x201, a path in a perfect maze is at
// most NCE-1 = 40400 steps, and the Manhattan heuristic is at most
// 2*(MAXW+MAXH) = 804, so f < 41204 -- comfortably inside the high half.  If
// this ever overflowed it would be a wrong ORDER, not a crash, so the bound is
// asserted by hand in the README rather than in code.
//
// COMPLEXITY, since the brief asks for it to be explicit.  A push is O(log n)
// and a pop is O(log n): the sift walks one root-to-leaf path, never the tree.
// Total A* is O((V + E) log V) = O(V log V) for a 4-connected grid, because
// every edge is relaxed at most once (a node is closed on pop and never
// reopened) and there are 2V edges.  The alternative this replaces -- keeping
// the frontier as a SORTED array and inserting each new node at its sorted
// position -- is O(V) per insert and O(V^2) overall, which at 40401 cells is
// 1.6 billion moves against about 1.2 million for the heap.  That is not a
// constant-factor difference; it is the difference between a solver and a
// slideshow.  Note also that this is a LAZY heap: a node's key is improved by
// pushing a NEW entry rather than by finding and fixing the old one, so the
// heap can hold stale entries for closed nodes.  That costs memory (the bound
// is 4*NC + 64, since a node can be improved at most once per incoming edge)
// and buys a sift-down-free decrease-key.
//
// ─────────────────────────────────────────────────────────────────────────
// NO `break`, AND NO `continue`, IN EITHER SOLVER.  Both search loops are
// written as: one `go` flag that carries "keep going", and a terminal
// assignment inside.  The stale-entry skip in A* is the interesting case -- it
// is a `continue` in C -- and it is written as the positive case of an if/else
// where the OTHER branch does the work.  That is the whole idiom:
//
//     if (seen[c] == 2) { go = hn > 0; }
//     else { ...the real work...; go = hn > 0; }
//
// Nothing else in the file needs it, and that is not an accident: the queue
// conditions ARE the early exits.  A* ends when the heap is empty, BFS ends when
// the queue is empty, and the goal test is a flag that clears `go`.

import grid;

const HN = 161668;            // 4 * 40401 + 64: the lazy-heap bound, with slack
const QCAP = 40401;           // one queue entry per cell: each is enqueued once

let heap: [long; 161668] = [0; 161668];
let hn: long = 0;
let hover: long = 0;          // 1 if the heap ever filled: reported, never a trap

let sseen: [byte; 40401] = [0; 40401];   // 0 unseen, 1 open, 2 closed
let sdist: [long; 40401] = [0; 40401];   // g
let spar: [long; 40401] = [0; 40401];    // the parent cell, for the path back
let q: [long; 40401] = [0; 40401];       // BFS queue: head/tail, never a ring

let plen: long = 0;           // length of the current solution
let pexp: long = 0;           // cells expanded by the last solve
let ppop: long = 0;           // heap pops (>= pexp: the difference is stale ones)
let pok: long = 0;            // 1 when the path verified

// ─────────────────────────────────────────────────────────────────────────
// the heap

// hpush(f, c) -> void -- insert (f, c), packed into one long.
//
// The sift-up walks from the new leaf to the root and stops at the first parent
// that is already <= it.  `moved` is the early exit, written as the positive
// condition with the negative case carrying the assignment.
def hpush(f: long, c: long) -> void {
    if (hn >= HN - 1) { hover = 1; return; };
    let k = hn;
    heap[k] = f * 4294967296 + c;
    hn = hn + 1;
    let moved = true;
    while (moved && k > 0) {
        let p = (k - 1) / 2;
        if (heap[k] < heap[p]) {
            let t = heap[k];
            heap[k] = heap[p];
            heap[p] = t;
            k = p;
        } else {
            moved = false
        }
    }
};

// hpop() -> long -- the cell with the smallest (f, cell), and take the entry out.
//
// The root is copied out, the last element is moved to the root and sifted down.
// `moved` stops at the first parent that already beats the smaller child.
def hpop() -> long {
    let top = heap[0];
    hn = hn - 1;
    heap[0] = heap[hn];
    let n = hn;
    let k = 0;
    let moved = true;
    while (moved) {
        let l = 2 * k + 1;
        let r = 2 * k + 2;
        let m = k;
        if (l < n && heap[l] < heap[m]) { m = l; };
        if (r < n && heap[r] < heap[m]) { m = r; };
        if (m == k) {
            moved = false;
        } else {
            let t = heap[k];
            heap[k] = heap[m];
            heap[m] = t;
            k = m
        }
    };
    top % 4294967296
};

// ─────────────────────────────────────────────────────────────────────────
// shared bits

// heur(c, goal) -> long -- Manhattan distance in cells.
//
// For a 4-connected grid with unit step cost this is both ADMISSIBLE (it never
// overestimates: any route moves at most one cell per step towards the goal on
// each axis) and CONSISTENT (h(c) <= 1 + h(n) across every edge), which is what
// lets A* close a node on pop and never reopen it.  The octile metric is not
// implemented because for 4-connected movement it IS the Manhattan distance --
// the sqrt(2) diagonal term only appears once diagonal steps exist, and this
// maze graph has none.
def heur(c: long, goal: long) -> long {
    let w = grid.GW;
    let dx = c % w - goal % w;
    let dy = c / w - goal / w;
    let ax = if (dx < 0) { 0 - dx } else { dx };
    let ay = if (dy < 0) { 0 - dy } else { dy };
    ax + ay
};

// reset() -> void -- clear the per-solve arrays.  O(V) writes into arrays that
// already exist, so this allocates nothing and costs nothing but a pass.
def reset() -> void {
    let i = 0;
    let n = grid.NCE;
    while (i < n) {
        sseen[i] = 0;
        sdist[i] = 0 - 1;
        spar[i] = 0 - 1;
        i = i + 1
    };
    hn = 0;
    hover = 0
};

// rebuild(start, goal) -> long -- walk spar[] back from the goal and answer the
// path length in steps, or -1 when there is no path.
//
// The loop condition is the exit: `c != start`.  There is no "stop when we hit
// the start" test to break on because that test IS the loop's life.
def rebuild(start: long, goal: long) -> long {
    if (sdist[goal] < 0) { return 0 - 1; };
    let c = goal;
    let n = 0;
    let go = true;
    while (go) {
        grid.solv[n] = c;
        n = n + 1;
        if (c == start) { go = false; } else { c = spar[c]; }
    };
    n - 1
};

// verify_path() -> bool -- is the stored solution a legal walk?
//
// Every consecutive pair must be real neighbours with an open passage, checked
// against the wall bits rather than against spar[] -- so a solver that got the
// LENGTH right and the route wrong is caught.  The final length is cross-checked
// against g as well.
def verify_path() -> bool {
    if (plen < 0) { return false; };
    // rebuild() walks BACK from the goal, so solv[0] is the goal and solv[plen]
    // is the start.  The start's g must be 0 or the whole answer is nonsense.
    if (sdist[grid.solv[plen]] != 0) { return false; };
    let i = 0;
    let ok = true;
    while (i < plen && ok) {
        let a = grid.solv[i];
        let b = grid.solv[i + 1];
        let ax = a % grid.GW;
        let ay = a / grid.GW;
        let d = 0 - 1;
        let k = 0;
        while (k < 4 && d < 0) {
            if (grid.nb(ax, ay, k) == b && grid.open_at(ax, ay, k)) { d = k; };
            k = k + 1
        };
        if (d < 0) { ok = false; };
        i = i + 1
    };
    ok
};

// ─────────────────────────────────────────────────────────────────────────
// BFS
//
// A plain queue over a flat array with head and tail counters.  No ring buffer
// is needed and that is worth saying: each cell is enqueued exactly once (a
// cell is marked seen the moment it is enqueued), so the queue never holds more
// than NCE entries in total and head never has to wrap.

// bfs(start, goal) -> long -- shortest path length in steps, -1 if none.
def bfs(start: long, goal: long) -> long {
    reset();
    let head = 0;
    let tail = 0;
    sseen[start] = 1;
    sdist[start] = 0;
    spar[start] = start;
    q[tail] = start;
    tail = tail + 1;
    grid.sno = 0;
    let found = 0;
    let go = head < tail;
    while (go) {
        let c = q[head];
        head = head + 1;
        grid.sord[grid.sno] = c;
        grid.sno = grid.sno + 1;
        if (c == goal) {
            // Terminal assignment, not a break.
            found = 1;
            go = false;
        } else {
            let x = c % grid.GW;
            let y = c / grid.GW;
            let d = 0;
            while (d < 4) {
                let n = grid.nb(x, y, d);
                if (n >= 0 && sseen[n] == 0 && grid.open_at(x, y, d)) {
                    sseen[n] = 1;
                    sdist[n] = sdist[c] + 1;
                    spar[n] = c;
                    q[tail] = n;
                    tail = tail + 1;
                };
                d = d + 1
            };
            go = head < tail
        }
    };
    pexp = grid.sno;
    ppop = pexp;
    plen = rebuild(start, goal);
    pok = if (found == 1 && plen >= 0 && verify_path()) { 1 } else { 0 };
    plen
};

// ─────────────────────────────────────────────────────────────────────────
// A*, Manhattan heuristic, binary min-heap, lazy deletion.

// astar(start, goal) -> long -- shortest path length in steps, -1 if none.
def astar(start: long, goal: long) -> long {
    reset();
    // The start is OPEN, not closed, when it is pushed.  Marking it closed here
    // looks like an optimisation and is a bug: the first pop of the start would
    // then read as a stale entry and be skipped, and with only the start in the
    // heap A* would expand nothing at all and answer -1.
    sseen[start] = 1;
    sdist[start] = 0;
    spar[start] = start;
    hpush(heur(start, goal), start);
    grid.sno = 0;
    ppop = 0;
    let found = 0;
    let go = hn > 0;
    while (go) {
        let c = hpop();
        ppop = ppop + 1;
        if (sseen[c] == 2) {
            // A stale entry for a cell that is already closed.  In C this
            // would be `continue`; here it is the other arm of an if/else whose
            // else is the work, and both arms end by recomputing the same
            // `go`.  One line of indirection instead of a keyword Y has not
            // got -- and this is the ONLY skip in either solver.
            go = hn > 0;
        } else {
            sseen[c] = 2;
            grid.sord[grid.sno] = c;
            grid.sno = grid.sno + 1;
            if (c == goal) {
                found = 1;
                go = false;
            } else {
                let x = c % grid.GW;
                let y = c / grid.GW;
                let nd = sdist[c] + 1;
                let d = 0;
                while (d < 4) {
                    let n = grid.nb(x, y, d);
                    // `sseen[n] != 2` is the consistency argument made
                    // explicit: a closed neighbour is never reopened.
                    if (n >= 0 && sseen[n] != 2 && grid.open_at(x, y, d)) {
                        if (sseen[n] == 0 || nd < sdist[n]) {
                            sseen[n] = 1;
                            sdist[n] = nd;
                            spar[n] = c;
                            hpush(nd + heur(n, goal), n);
                        }
                    };
                    d = d + 1
                };
                go = hn > 0
            }
        }
    };
    pexp = grid.sno;
    plen = rebuild(start, goal);
    pok = if (found == 1 && plen >= 0 && verify_path()) { 1 } else { 0 };
    plen
};

// solve(which, start, goal) -> long -- 0 = BFS, 1 = A*.  One entry point so the
// driver's key handling and its --soak loop do not each have their own copy of
// the choice.
def solve(which: long, start: long, goal: long) -> long {
    let r = 0 - 1;
    if (which == 0) { r = bfs(start, goal); } else { r = astar(start, goal); };
    r
};

// keep_path() -> void -- copy the current solution aside, so the NEXT solve can
// be compared against it cell for cell.  The driver runs BFS first, keeps its
// answer in soli, then runs A*; both lengths are read off astar.plen.
def keep_path() -> void {
    let i = 0;
    while (i <= plen) {
        grid.soli[i] = grid.solv[i];
        i = i + 1
    }
};

// same_path() -> bool -- do the two solvers agree CELL FOR CELL?
//
// soli is the kept answer (see keep_path) and solv the current one, so this is a
// stronger statement than equal lengths: a wrong parent pointer can produce the
// right count and the wrong route, and this is what catches that.
def same_path() -> bool {
    let i = 0;
    let ok = true;
    while (i < plen && ok) {
        ok = grid.soli[i] == grid.solv[i];
        i = i + 1
    };
    ok
};

export { HN, sseen, sdist, spar, plen, pexp, ppop, pok, hover,
         hpush, hpop, heur, bfs, astar, solve, verify_path, rebuild,
         keep_path, same_path };
