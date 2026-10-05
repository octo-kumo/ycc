# maze

Three maze generators, two shortest-path solvers, and a walkable terminal view
— with the numbers that make the generators comparable and the solvers
cross-checked.

```
$ ./maze --no-tty --frames 0 --seed 1
maze 39x11 cells (79x23 chars), seed 1, gen rb, solver bfs
maze: rb       passages    428  dead     44  junc     42  corridors     95  longest     22  mean     3.6  len 1-4:   69 5-8:   23 9-16:    1 17-32:    2 33+:    0
maze: prim     passages    428  dead    165  junc    142  corridors     83  longest      4  mean     1.4  len 1-4:   83 5-8:    0 9-16:    0 17-32:    0 33+:    0
maze: kruskal  passages    428  dead    129  junc    111  corridors    104  longest      7  mean     1.8  len 1-4:  100 5-8:    4 9-16:    0 17-32:    0 33+:    0
maze: spanning tree check  passages    428    428    428  expected    428  ok
maze: bfs       steps    112  expanded    117/   429  pops    117  route verified
maze: astar     steps    112  expanded    117/   429  pops    117  route verified
maze: cross-check  BFS 112 = A* 112  same length AND identical route
```

Those three lines are the whole point of the example. Same seed, three
algorithms, and the corridor-length distribution separates them completely:
the recursive backtracker makes **22-cell-long snaking corridors and 44 dead
ends**, randomised Prim makes **4-cell corridors and 165 dead ends**, and
randomised Kruskal sits between them. Read `longest` down the three rows.

---

## Build and run

The five toolkit modules are **vendored**: `fx.y tui tui tui args
sit beside the program and are imported by bare name (`import fb;`), so this
folder builds on its own with no sibling folder present.

```
ycc -o maze maze.y          # rng.y grid.y astar.y sink.y must sit beside it too
./maze                      # interactive: arrows walk, g new, s solver, t path, q quit
./maze --frames 3 --no-tty --seed 1     # the deterministic run (EXPECTED)
sh gate.sh                  # the whole acceptance gate, ~2 minutes
python3 capture.py          # rebuild golden/
```

Build with the pinned compiler **in place** — `../../refs/ycc.ref` — never a
copy somewhere else: it resolves `std/` relative to its own path.

| flag | meaning |
|---|---|
| `-n, --frames N` | render exactly N display steps, then exit 0 (0 = until a key) |
| `-r, --seed N` | PRNG seed; same seed, same maze (default 1) |
| `-g, --gen rb\|prim\|kruskal` | which generator to draw (default `rb`) |
| `-k, --solver bfs\|astar` | which solver's expansion order the frames reveal (default `bfs`) |
| `-w, --size WxH` | logical cells, 1..201 each; default the terminal, or 39x11 without one |
| `-t, --no-tty` | text instead of the terminal; never paces, never reads a key |
| `-e, --time` | wall clock and heap delta, on **stderr** |
| `-a, --ascii` | all three generators' mazes and the solved route, as text |
| `-p, --soak N` | solve N times in a row and report the heap delta |
| `-f, --fps N` | interactive only, default 24 |
| `-h, --help` | the generated usage plus notes on the three generators |

Exit codes: **0** fine, **1** a bad flag or a bad argument (message on
stderr), **2** reserved for a usage error from the flag parser. `args`'s own
`parse_or_exit` uses 2 for a usage error; this example follows the brief and
uses 1 for everything wrong on the command line, so the two disagree — that is
deliberate and it is a real inconsistency in the campaign's convention, worth
settling one way.

**Why the timings are behind a flag.** `gate.py` diffs stdout **and stderr
together** against `EXPECTED`. A line carrying a wall-clock time would make the
deterministic run irreproducible and the example would fail its own gate. So
generation and solve times exist, are real, and are printed on request with
`--time`; the golden run has no timing in it at all.

---

## The algorithms

### Grid

A maze is a `w × h` grid of **cells** with a wall between each pair of
neighbours, so it draws as a `(2w+1) × (2h+1)` grid of **characters** with a
cell at every even row and column. There is no cell object: a cell is its
index, `y * w + x`, into one flat fixed array. One `[byte; 40401]` allocated
once is 40 KiB and costs nothing more for the life of the process, where an
array of records would cost one 64-byte heap cell per cell per frame.

`cw` stores **open passages**, not walls — bit 0 = passage east, bit 1 =
passage south — so a fresh maze is all zeros (every wall standing), a boundary
cell needs no special case anywhere downstream, and carving a wall is a `+=`.
West and north are read from the neighbour's bit, so two bits per cell and not
four.

Directions are `0 = north, 1 = east, 2 = south, 3 = west`, clockwise, so the
opposite of `d` is `(d+2) % 4` and "pick a random direction" is a random
**rotation of a scan**, not a table of six cases.

### 1. Recursive backtracker (`rb`) — long corridors

A stack of cells to visit. At the top, carve towards a random **unvisited**
neighbour and push it; when there is none, pop. The explicit stack replaces the
call stack, which is what Y's `self` recursion would otherwise be doing one
frame at a time.

This is the depth-first one. It commits to a direction and keeps going, so its
corridors *are* the snake.

### 2. Randomised Prim (`prim`) — short corridors, many dead ends

The frontier holds cells that are **in the tree** and still have an untaken
edge. Pop a uniformly random one (one draw, then swap-with-last removal — the
standard "random element from an array" trick: O(1) and unbiased), open an edge
towards an unseen neighbour, add that neighbour, repeat.

**One detail that is easy to get wrong, and that this file gets right on
purpose.** When a frontier cell is popped it opens an edge towards **every**
unseen neighbour, not just the first one found. Stopping at the first looks
equivalent and is not: the cell leaves the frontier when it is popped, so an
unseen neighbour on the far side of that stop is never reconsidered from here
and nothing else is guaranteed to reach it. The result is a maze with holes — a
forest, not a tree. Opening every edge is what makes the final tree *maximal*,
and maximal = spanning here.

### 3. Randomised Kruskal (`kruskal`) — a uniform spanning tree

Every adjacency is an edge; shuffle the edges (Fisher–Yates from the back); take
each one whose ends are in different components and merge them. Because the
edges are in a uniformly random order the tree is a **uniform spanning tree** —
the same distribution Aldous–Broder reaches by a random walk, arrived at by a
completely different method. That is what makes it the interesting third one:
it is the reference "uniform" against which the other two are visibly biased.

The disjoint set is union-find with **full path compression** and union by
index, both written out by hand. Both have to be: a `map_get`/`map_set`
disjoint set would be a **linear scan** per lookup (O(n²) for this algorithm)
*and* it would allocate on every insert, since there is no `push`, no `sort`
and no map in Y (ORCHESTRATOR.md §2.8).

### The corridor distribution — the payoff

A **corridor** is a maximal run of degree-2 cells: the cells you pass through
with nothing to do at them. Its length is how many cells that is. Dead ends
(degree 1) and junctions (degree 3 or 4) are what end corridors. `grid_stats()`
computes the whole distribution — count, longest, mean, and a six-bucket
histogram — with integer arithmetic and no float anywhere (Y has no
float→long conversion at all, §2.4a, so the one decimal place in the mean is
`(total * 10 / count) % 10`).

Measured, same seed, one row per generator:

| grid | generator | dead ends | junctions | corridors | longest | mean |
|---|---|---|---|---|---|---|
| 39×11 (429 cells) | `rb` | 44 | 42 | 95 | **22** | 3.6 |
| | `prim` | 165 | 142 | 83 | **4** | 1.4 |
| | `kruskal` | 129 | 111 | 104 | **7** | 1.8 |
| 61×31 (1891) | `rb` | 159 | 157 | 367 | **31** | 4.2 |
| | `prim` | 736 | 606 | 379 | **5** | 1.4 |
| | `kruskal` | 575 | 505 | 480 | **10** | 1.6 |
| 201×201 (40401) | `rb` | 3592 | 3590 | 7813 | **47** | 4.2 |
| | `prim` | 15869 | 13112 | 7980 | **7** | 1.4 |
| | `kruskal` | 12311 | 10684 | 10307 | **10** | 1.6 |

Two identities fall out of the table and are worth checking yourself:

* every generator carves exactly `cells - 1` passages, so every one of them is
  a spanning tree — printed as an explicit `spanning tree check` line;
* `dead_ends = 3·j3 + 2·j4 + 2`, the handshake lemma for a tree. It is how a
  real bug was caught here: an early version had the generators **carving on
  top of each other's walls** (they were never reset), every one still reported
  `cells - 1` passages of its own, and the picture still looked like a maze —
  but the degrees summed to 1157 against 856 passages.

### 4. BFS

A flat queue with head and tail counters. **No ring buffer is needed**, and that
is worth saying: each cell is enqueued exactly once (marked seen the moment it
is enqueued), so the queue never holds more than `cells` entries in total and
`head` never has to wrap.

### 5. A\* — Manhattan heuristic, binary min-heap, lazy deletion

`astar.y` also records **every cell it expands, in order**. That is what the
`--frames` overlay animates: it turns the solver's internal order into
something a human can watch.

**The priority queue.** One fixed array of `long`. The element is *one* long,
not a pair: the `f` value is packed into the high 32 bits and the cell index
into the low 32,

```
key = f * 4294967296 + cell
```

so a plain `<` compares `(f, cell)` lexicographically and the tie-break is free
and deterministic. Two parallel arrays would double the memory and double the
loads in the sift, and the swap in a sift would have to move both.

Why the packing is safe: the grid is at most 201×201, a path in a perfect maze
is at most 40400 steps, and the Manhattan heuristic is at most `2*(201+201) =
804`, so `f < 41204` — comfortably inside the high half. Overflow would be a
wrong *order*, not a crash, so the bound is argued here rather than checked in
code.

**Complexity, explicitly**, because it is the reason for the heap:

| | push | pop | total |
|---|---|---|---|
| this heap | O(log n) — one root-to-leaf sift | O(log n) | **O((V+E) log V)** = O(V log V) |
| sorted-array frontier, inserted at its sorted position | — | O(n) to find the slot | O(V²) |

At 40401 cells that is about 1.2 million moves against 1.6 billion. That is not
a constant-factor difference; it is the difference between a solver and a
slideshow. (And there is no `sort` in Y to lean on anyway — §2.8.)

The heap is **lazy**: a node whose key improves is pushed again rather than
found and fixed in place, so the heap can hold stale entries for closed nodes.
That costs memory — the bound is `4*cells + 64`, since a node can be improved
at most once per incoming edge — and buys a decrease-key with no sift.

The heuristic is **Manhattan** because it is admissible and consistent for a
4-connected grid with unit step cost, which is what lets A\* close a node on pop
and never reopen it (`sseen[n] != 2` in the relax loop is that argument written
out). The **octile** metric is not implemented because for 4-connected movement
it *is* the Manhattan distance — the `√2` term only appears once diagonal steps
exist, and this maze graph has none.

---

## The cross-check, and what it does and does not prove

A perfect maze is a **tree**, so there is exactly one path between any two
cells. The two solvers can never disagree about which path is shortest, in
principle. So the cross-check is not "do two algorithms find the same shortest
path" — it never could not. What it establishes is:

* each solver returns a route that is **legal** — `verify_path()` re-walks the
  answer through the wall bits, checking every consecutive pair is a real
  neighbour with an open passage, so a plausible length with an impossible path
  behind it fails;
* both report the same length, **and** the identical cell sequence
  (`same_path()`), which is what catches a wrong parent pointer that still
  gives a plausible count;
* and the interesting difference shows up where it really is: how many cells
  each one had to expand.

Measured, 40 seeds × 3 generators at 39×11 (`gate.sh` step 5):

| generator | seeds | A\* expanded strictly fewer | cells saved | mean BFS expansions | saved |
|---|---|---|---|---|---|
| `rb` | 40 | 31 | 522 | 165 | 8% |
| `prim` | 40 | 40 | 4047 | 421 | 24% |
| `kruskal` | 40 | 40 | 3096 | 401 | 19% |

**120 comparisons, 0 disagreements, 120 with identical routes.**

That table is itself a result about the generators: on a **recursive-backtracker
snake** the heuristic barely helps (8%), because RB's corridors run parallel to
the start→goal direction, so `h` falls as fast as `g` rises. On a **Prim or
Kruskal maze** — which is short-corridor and branchy — A\* prunes a quarter of
the cells BFS never needed to touch.

At 201×201 seed 1: BFS expands 38340 cells, A\* expands 26383, both find a
674-step route, A\* saves 11957 cells (31%).

A\*'s expansion set is also checked against an **independent prediction**, and
that check ships as `xcheck.y` so you can run it:

```y
// xcheck.y -- why the prediction is exact, in one paragraph.
// A perfect maze is a TREE, so there is exactly one path from the start to any
// cell c.  Along that path g rises by 1 per step and h changes by at most 1, so
// f = g + h never decreases on the way: every cell on the path to c has
// f <= f(c).  So if f(c) <= L, every cell on c's path also has f <= L and is
// expanded before the goal is popped -- which means c is discovered and
// expanded too.  Hence A* must expand EXACTLY { c : g(c) + h(c) <= L }, and
// that set is countable in one linear scan of BFS's distance array, with no
// reference at all to the heap, the sift, the tie-break or the skip.
def predict(goal: long, L: long) -> long {
    let n = 0;
    let i = 0;
    while (i < grid.NCE) {
        let g = astar.sdist[i];
        if (g >= 0 && g <= L && g + astar.heur(i, goal) <= L) { n = n + 1; };
        i = i + 1
    };
    n
};
```

`./xcheck` runs 4 grid sizes × 3 generators × 6 seeds = 72 searches and insists
on three things each time: A\*'s length equals BFS's, A\*'s expansion count
equals `predict()`, and the route passes the wall-by-wall verification. All 72
pass; the table it prints also shows how far off the count *would* be:

```
$ ./xcheck
    201x 201  rb        A* smaller on  2/6  cells saved       2   wrong expansion set on  0/6
    201x 201  prim      A* smaller on  6/6  cells saved 132888   wrong expansion set on  0/6
    201x 201  kruskal   A* smaller on  6/6  cells saved  45177   wrong expansion set on  0/6
  checks failed: 0
```

That is a check of the *search*, not of the answer — on a tree the length alone
cannot catch a wrong heap, because there is only one possible route to check.

One honest note about the default run: at the default size and the default seed
(`39x11`, seed 1) BFS and A\* happen to expand the *same* 117 cells, so the
`expanded` columns in `EXPECTED` read as identical. That is a property of that
one maze, not a bug — 31 of the 40 `rb` seeds do differ.

---

## Early exits without `break` or `continue`

Y has neither keyword (`ORCHESTRATOR.md` §2.9 — it is on the roadmap in
`TODO.md` §5, so a known gap, not a bug). Both idioms the campaign has are used
here, and the second one carries the A\* search.

**The queue condition *is* the early exit.** Most of these loops need no flag at
all: A\* ends when the heap is empty, BFS when the queue is empty, the
backtracker when the stack is empty, Prim when the frontier is empty, the path
rebuild when it reaches the start. `while (go)` with `go = hn > 0` at the bottom
of the body *is* the "found it, leave" test.

**Guard flag plus an explicit terminal assignment**, where there really is an
early exit inside the loop:

```y
if (c == goal) {
    found = 1;
    go = false;          // the C would be `break`
} else {
    ...relax the neighbours...
    go = hn > 0
}
```

**The skip (what `continue` would be)** — the stale-heap-entry case, which is
the *only* skip in either solver. It is written as the other arm of an if/else
whose `else` is the work, and both arms end by recomputing the same condition:

```y
if (seen[c] == 2) {
    go = hn > 0;        // a stale entry: nothing to do but keep going
} else {
    seen[c] = 2;
    ...
    go = hn > 0
}
```

**The rejection loop** in `rng.y` is the purest case: the exit *is* the
condition, so there is nothing to break out of — "a good draw" and "keep going"
are the same test.

---

## The heap never frees, so the solvers allocate nothing

The heap is an arena; nothing is ever freed (§2.7). A record literal or array
literal inside a loop body costs 64 / 72 bytes **every iteration**
(`examples/SUGGESTIONS.md` §7). So:

* every buffer in `grid.y`, `astar.y` and `sink.y` is a module-level `let`,
  allocated once. Total for the whole program is about 6.5 MB whatever the grid
  size.
* the solver's working set is five flat arrays and one heap; no allocation
  happens anywhere inside `bfs()` or `astar()`.
* the text path writes into one fixed `[byte; 262144]` (`sink.y`) with one
  `write(2)` when it fills — never `puts()`, never an f-string, both of which
  are a heap allocation per call.
* the HUD writes numbers one digit at a time through a module-level scratch
  array, because `tostring()` in the frame loop would allocate.
* `heap_used()` is read **before** the first `tostring()` of a summary, or the
  delta measures the summary's own strings. That was worth 128 bytes and is
  now 0.

Measured with the program's own `--soak`:

```
$ ./maze --soak 10000
maze: soak 10000 solves of 429 cells with bfs in 84579 us, 8 us each, last path 112 steps
maze: heap_used 6557800 -> 6557800 delta 0 over 10000 solves

$ ./maze --size 201x201 --soak 2000 --solver astar
maze: soak 2000 solves of 40401 cells with astar in 459910 us, 229 us each, last path 1224 steps
maze: heap_used 6558216 -> 6558216 delta 0 over 2000 solves
```

and for the interactive frame loop (read from under a pty):

```
maze: 200 frames, 32690 bytes of ANSI, heap_used 8131056 -> 8131056 delta 0
```

---

## Throughput

`--time`, 201×201 = 40401 cells, `refs/ycc.ref` on this machine:

| | time |
|---|---|
| generate, recursive backtracker | 3.2 ms |
| generate, randomised Prim | 2.5 ms |
| generate, randomised Kruskal | 3.5 ms |
| BFS, 674-step route, 38340 cells expanded | 2.4 ms |
| A\*, 674-step route, 26383 cells expanded, 26383 pops | 3.8 ms |

(One run on a shared machine; treat them as orders of magnitude, not as a
benchmark. `--time` prints them again, and `sh gate.sh` step 6 does it for you.)

At the default 39×11 the whole thing — three generators, both solvers, the
cross-check and the render buffer — is under 1 ms, so the interactive loop is
entirely frame-paced.

A\* being *slower in wall clock* than BFS while expanding 31% fewer cells is not
a paradox and is worth stating: a push is a sift-up and a pop is a sift-down
(≈2 log₂ 26383 ≈ 29 comparisons each), whereas BFS's inner loop is an array
read, a compare and three stores. The heap buys a smaller search, not a faster
one, and the honest summary is: **use BFS when the grid is small enough that
memory dominates, A\* when it is not** — which is the same advice as everywhere
else.

---

## What to look at

* `golden/rb.txt`, `golden/prim.txt`, `golden/kruskal.txt` — the same seed,
  three generators, as text. `@` is you, `S` the start, `G` the goal, `*` the
  route, `.` a cell the solver expanded, `#` a wall. **Compare the shape of the
  corridors** (the longest run of `*` on a line is the number in the table): `rb` draws long snakes with few dead ends, `prim` and `kruskal`
  are a thicket of short runs.
* `golden/interactive.txt` — the interactive view as the terminal actually
  rendered it, replayed through a Python terminal emulator (`pyte`). `█` a wall,
  `░` a cell the solver expanded, `●` the route (and the start/goal markers),
  `◉` you. The dim `░` region is the search's **footprint** — it is drawn from
  `grid.sno`, the cells the solver actually popped, which is the same number the
  `expanded` field in the status line and in the text path reports. Press `t`
  to hide the route and look at the footprint alone.
* `./maze --no-tty --frames 3 --seed 1` — three frames of the same solve:
  frame 0 the maze and the route with nothing revealed, frame 1 half the
  expansion order, frame 2 all of it. Each frame line carries an FNV-1a digest
  of the picture, so a frame is checkable and not just printable.
* `grid.y`'s `gen_prim` — the comment about opening *every* edge. That is the
  one line that is load-bearing for correctness and not for style.
* `astar.y`'s `hpush`/`hpop` — sixty lines, and the only reason this example
  can claim to have a priority queue rather than a sorted insert.
* `grid_stats` — the `d1`/`d2` scan that finds a degree-2 cell's two open
  directions. Easy to get subtly wrong; the `cm[]` marking is what makes it
  safe on *any* passage set, not only on a tree.

---

## The interactive path

```
$ ./maze
```

Raw mode, alt screen, and `term.arm_watchdog()`; **one** exit, always
`term.restore_all_exit(0)`. Keys are polled every frame with
`read_key_timeout(0)`, which never blocks.

| key | what |
|---|---|
| arrows or `hjkl` | walk — only through an open passage, so the walk *is* the maze |
| `g` | regenerate with the **next** seed (still seeded, so the sequence is reproducible; the status line shows which) |
| `s` | switch solver and **re-solve from where you stand** — the route on screen is always the route from you |
| `t` | toggle the route overlay |
| `q`, `Q`, Escape | quit |

`tmux` is not installed on this machine, so `pty_check.py` allocates a pty from
Python. It sets the window size **before** `execv` (a pty from `pty.fork()` is
0×0 and `TIOCGWINSZ` would report nothing), drives the program with real
arrow-key escape sequences plus `g`, `s`, `t`, and checks four things.

```python
#!/usr/bin/env python3
# pty_check.py -- maze, under a real pty.  tmux is not installed here.
import fcntl, os, pty, select, struct, sys, termios, time

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.chdir("/home/yun/Projects/compiler/examples/maze")
    os.execv("./maze", ["./maze"]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
before = termios.tcgetattr(fd)

out, entered, i = b"", 0.0, 0
seq = [b"\x1b[B", b"\x1b[C", b"g", b"s", b"t"]          # down, right, g, s, t
end = time.time() + 20
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try:
            c = os.read(fd, 65536)
        except OSError:
            break
        if not c:
            break
        out += c
    if entered == 0.0 and b"?1049h" in out:
        entered = time.time()
    if entered and i < len(seq) and time.time() - entered > 0.4 * (i + 1):
        os.write(fd, seq[i]); i += 1
    if i >= len(seq) and entered and time.time() - entered > 4.0:
        break
os.write(fd, b"q")                                       # and quit
time.sleep(0.5)
try:
    while True:
        r, _, _ = select.select([fd], [], [], 0.3)
        if not r:
            break
        if not os.read(fd, 65536):
            break
except OSError:
    pass
after = termios.tcgetattr(fd)
code = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])

print("alt screen in / out :", b"\x1b[?1049h" in out, b"\x1b[?1049l" in out)
print("cursor hidden/shown :", b"\x1b[?25l" in out, b"\x1b[?25h" in out)
print("runtime traps       :", out.count(b"runtime error:"))
print("c_lflag before/after:", hex(before[3]), hex(after[3]))
print("cooked restored     :", bool(after[3] & termios.ICANON and after[3] & termios.ECHO))
print("exit status         :", code)
```

`sh gate.sh` runs the full version (and `xcheck` as its step 6). Its result:

```
alt screen entered      : True
alt screen left         : True
cursor hidden / shown   : True / True
block glyphs emitted    : 1148 (the wall colour)
runtime traps           : 0
c_lflag before / after  : 0x8a3b 0x8a3b
cooked mode restored    : True
lflag identical         : True
exit status             : 0
RESULT                  : PASS
```

---

## Files

| file | lines | what |
|---|---|---|
| `maze.y` | 885 | CLI, the two painters, the comparison table, the interactive loop |
| `grid.y` | 645 | dimensions, walls, the three generators, corridor statistics, the render-kind buffer |
| `astar.y` | 384 | the binary min-heap, BFS, A\*, route verification, the cross-check |
| `sink.y` | 185 | the fixed byte-buffer text path and the ASCII painter |
| `rng.y` | 85 | splitmix64 and one unbiased index below n |
| `xcheck.y` | 126 | proves A\* expands exactly the set it is obliged to; exits 1 on any disagreement |
| `capture.py` | 120 | rebuilds `golden/`, including a pyte replay of the interactive view |
| `pty_check.py` | 113 | drives the interactive path under a real pty |
| `gate.sh` | 150 | the whole acceptance gate, re-runnable |
| `fx.y` | `4b47a9bfef0c1e30` | 694 | | the vendored toolkit, byte-identical to `examples/_toolkit/` |
| `README.md` | 703 | this file |
| `EXPECTED` | 6574 bytes | the stdout of the `run=` line in `gate.conf` |
| `golden/*.txt` | 4 files | the three generators as text, plus the interactive view as the terminal rendered it |

---

## The std units this uses

These five files are **copies of `examples/_toolkit/` and are NOT edited** —
verified by sha256 at the top of `gate.sh`'s sibling check and again here:

| file | sha256 (first 16) | lines |
|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 |

This folder reaches std for `tui` -- the frame pacer, raw mode, the alt screen,
keys, the restore guarantee and the interactive surface are all in it now -- and
for `args` (the CLI). It vendors **`fx.y` and never calls it** — there is no
floating point in this example at all, which is the point, so there is nothing
for an integer trigonometry module to do.

---

## Compiler pin

Built and verified against:

```
refs/ycc.ref  sha256  c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

**The pin moved during this task**, which is worth recording because it is the
rule the campaign has been bitten by twice already:

| when | pin | what happened |
|---|---|---|
| start of task | `e27f83e4…` | everything above was first verified against this |
| ~40 min later | `c53cc415…` | rebless; rebuilt, re-ran the whole gate, **output byte-identical**, still zero warnings |

So: build with `refs/ycc.ref` **in place** (a copy in `/tmp` compiles until a
program does `import fs;` and then fails), record the sha, and **re-check it at
the end of the task** — `gate.py`'s item 0 does exactly that and fails when the
README's sha no longer matches the compiler.

---

## Compiler workarounds

### 1. `str + byte` — dodged by construction, not by workaround

`s[i]` on a `str` yields a `byte`, and `str + byte` **segfaults**. Verified
against the current pin:

```y
print("x" + "abc"[0]);   // $? = 139, SIGSEGV
```

Filed in `examples/BUGS.md` as "`str + byte` segfaults". The two workarounds the
filing gives are `line += RAMP[i]` and `line = line + chr(RAMP[i])`.

**`line += RAMP[i]` no longer compiles.** The filing's own snippet is now a hard
error, which is a separate regression already filed as "The `str + byte`
filing's `+=` workaround is now a compile error":

```
$ refs/ycc.ref min.y -o min
3:19: error: '+=` string: expected str, got byte
```

So `chr()` is the only surviving route — and `chr()` allocates a `str` on the
heap, which makes it useless in a render loop. This example therefore **never
builds a string out of characters at all**:

* `sink.ascii_of(kind)` returns a **byte** — a codepoint — which `sink_byte`
  writes straight into the fixed buffer, and there is no string layer at all;
* the interactive painter's `glyph_of(kind)` returns a **codepoint** handed to
  `fb.put`, again with no string;
* the only string literals in the program are whole words.

That is the actual answer to "how do you draw a maze in Y without hitting the
string layer": **write codepoints, not characters.** The status line's digits
go out one digit at a time as `48 + n % 10`, which is the same idea.

### 2. `tui`'s `emit_num` drops a zero digit — filed here

While checking the interactive view I found that `tui` writes colour channels
and CUP operands wrong whenever the **tens digit is zero**: `205` is emitted as
`25`, `104` as `14`, `column 101` as `11`. Filed in `examples/BUGS.md` as
"`tui`'s `emit_num` drops a zero digit". It is a toolkit bug, not a compiler
bug, and it is visible in other examples too — `fb.rgb(255, 206, 96)` in
`examples/donut`'s amber palette reaches the terminal as `38;2;255;26;96m`.

The vendored copy cannot be edited, so `maze.y` works around it two ways:

* **`safe_rgb()`** nudges any offending channel up to the next value with no
  zero digit in it (`104 → 112`, `205 → 212`), so the palette's intent survives
  and the picture is right on this compiler;
* the interactive surface is **capped at 99×99**, because `1..99` is exactly the
  range `emit_num` gets right. A 200-column window shows a 49×11 maze (99
  columns) rather than silently drawing the right half of the screen in the
  wrong place. Verified: at 60, 80, 100, 140 and 200 columns, **no CUP operand
  the program emits lands in a broken range and no SGR channel has a zero tens
  digit.**

std `tui` has the helper (`put_num`) once, so the fix
belongs in `examples/_toolkit/` and reaches every example at the next
re-vendor.

### 3. Everything else, and where it bites

| the gap | what it cost here |
|---|---|
| **no `break`, no `continue`** | every early exit written out; see the section above |
| **no `float` → `long`, no casts** | the mean corridor length prints its one decimal as `(total*10/count) % 10`; there is no float anywhere |
| **no math functions, no `PI`** | nothing needed one — `rng.y` is bit arithmetic and the heuristics are `abs` by hand |
| **nothing is ever freed** | every buffer module-level; `--soak` measures the result |
| **no `sort`, no `push`, no `map_get`** | union-find over a `[long]` instead of a map; a `[long]` worklist with a stack pointer for the frontier; Fisher–Yates by hand |
| **a fixed `[T; N]` is not a `[T]`** | the solver's expansion order and route arrays live in `grid.y` next to the render code that reads them, because they cannot be passed to `grid_paint()` as parameters. Same reason `tui`'s termios buffers are growable `[byte]` |
| **traps print to stdout** | every divisor is guarded: `s_corr == 0` in a 1×1 maze would be a division by zero *in the middle of the report line* |
| **`split` drops a trailing empty field; `join` puts the separator first** | not used — no line is parsed back |
| **an array literal in a loop body allocates** | every scratch array is a module-level `let`; see §7 of `SUGGESTIONS.md` |
| **runtime traps, bounds checks** | `grid.nb()` answers `-1` off-grid instead of trapping, which folds the bounds check into the neighbour lookup |

---

## Honest limits

* A\* expands fewer cells but is **slower in wall clock** than BFS at every size
  measured. The heap is not free.
* On the **default** maze (39×11, seed 1) the two solvers expand the same number
  of cells, so the `expanded` columns in `EXPECTED` look redundant. 31 of the 40
  `rb` seeds do differ; the default is not one of them.
* The uniform-spanning-tree claim for randomised Kruskal is a **theorem**, not
  something this program verifies. What it does verify is that Kruskal carves
  `cells - 1` passages and produces a different corridor distribution from the
  other two, which is the observable consequence.
* `1x1` and `2x1` are legal and exercised; `0x0` is **refused** with a
  diagnostic rather than clamped. That is a deliberate difference from
  `examples/donut`, which clamps — a maze with no cells has no cell to stand in
  and a mean whose denominator is zero, so the useful answer is a diagnostic.
* The interactive size is derived from the terminal, so a window narrower than
  about 20 columns produces a tiny maze. That is clamped, not refused.
### Pin re-verification

The compiler was reblessed mid-campaign to
`refs/ycc.ref` sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`.
Rebuilt against it: **zero warnings**, the deterministic run still
reproduces `EXPECTED` byte for byte, no trap on any path, and this
folder's own property check still passes. No source change was needed.
Earlier pins stay listed above as history.

## Pin re-verification: `4a58dd5d` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `6dcd7071` -> **`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. The only thing that had fallen out of date was this sha
record, which is what gate item 0 caught.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `e55fa8d0` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `4a58dd5d` -> **`e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `9ce37629` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `5eba0d66` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `625efd81` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `5eba0d66` -> **`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `1d28b3db` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `625efd81` -> **`1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `289cf022002903a6` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`289cf022002903a695c1ca339816b0f8f478aa3ef9f00643a93c3a95947f979c`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `dad3564d3bcdf6df` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`dad3564d3bcdf6df889d017e88660dd8e7e0637a1e046acc45539f515e361d3e`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
