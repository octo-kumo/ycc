# wavefunction — wave function collapse by constraint propagation

A tile set with adjacency rules, an arc-consistent propagator, a weighted
lowest-entropy collapse with backtracking, a framebuffer view in the terminal,
and a property battery that checks the finished grid against the rule rather
than against a golden file.

    build   ../../refs/ycc.ref wavefunction.y -o wavefunction
    run     ./wavefunction                                   interactive
            ./wavefunction --frames 3 --no-tty --seed 1      the golden run
            ./wavefunction --check                           the property battery
            python3 oracle.py                                the Python cross-check
            python3 pty_check.py ./wavefunction             the interactive path
            python3 pty_check.py ./wavefunction --save golden/interactive.txt

Pinned compiler: `refs/ycc.ref`, sha256
**`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`**.
(The pin moved during this example's writing — it was
`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8` when the
solver was first built. `EXPECTED` was regenerated under the new pin and
reproduces byte for byte; nothing was hand-edited.)

## What it is

Sixteen tiles. Each is a set of four socket bits — N=1, E=2, S=4, W=8:

| idx | sockets | name | weight | ascii | glyph |
|----|---------|------|--------|-------|-------|
| 0 | — | `empty` | 6 | `.` | (space) |
| 1 | N | `end-N` | 1 | `\|` | │ |
| 2 | E | `end-E` | 1 | `-` | ─ |
| 3 | S | `end-S` | 1 | `\|` | │ |
| 4 | W | `end-W` | 1 | `-` | ─ |
| 5 | N+S | `straight-NS` | 3 | `\|` | │ |
| 6 | E+W | `straight-EW` | 3 | `-` | ─ |
| 7 | N+E | `elbow-NE` | 4 | `L` | └ |
| 8 | E+S | `elbow-ES` | 4 | `7` | ┌ |
| 9 | S+W | `elbow-SW` | 4 | `J` | ┐ |
| 10 | W+N | `elbow-WN` | 4 | `F` | ┘ |
| 11 | N+E+S | `tee-NES` | 1 | `+` | ├ |
| 12 | E+S+W | `tee-ESW` | 1 | `+` | ┬ |
| 13 | S+W+N | `tee-SWN` | 1 | `+` | ┤ |
| 14 | W+N+E | `tee-WNE` | 1 | `+` | ┴ |
| 15 | N+E+S+W | `cross-NESW` | 1 | `*` | ┼ |

Sixteen is the most tiles that fit in one 64-bit mask, which is what makes a
cell's possibility set a single integer and the union of what may face it a
single OR. The sixteen socket patterns are exactly the sixteen subsets of
{N,E,S,W}, so the rule has no blind spot: every pattern is available everywhere.

**The rule, in one line:** two tiles may be neighbours only when they agree
about the edge they share — set against set, clear against clear. A cell on the
edge of the grid may not carry a socket facing off it. That is the whole
constraint system, and everything the property battery knows is derived from it.

`--tiles` picks a subset: `all` (the sixteen), `loop` (everything but `empty`, so
every cell carries a socket and the finished grid is a set of closed loops and
nothing else), `lines`, `elbows`, `ends`, `straights` (the two straights only —
**unsatisfiable on any grid with a corner**, see below) and `cross`.

## The search

1. Every cell starts as the full available set, narrowed by the boundary.
2. **Propagate.** A worklist of cells whose mask shrank; for each, every
   neighbour's mask is intersected with the union of what can face it. A mask
   that goes empty is a contradiction. Masks only ever shrink, so the worklist
   drains and the fixpoint is reached.
3. **Choose** the uncollapsed cell of lowest Shannon entropy and collapse it to
   one tile drawn in proportion to the weights.
4. On a contradiction, **rewind** the undo log to the last decision and choose
   again. A step budget (4 000 000) turns "no solution" and "gave up" into two
   different, both non-zero, messages rather than a hang.

### The generator

Step 3's draw comes from **`import random`** (`src/y/std/random.y`, splitmix64):
`setup()` calls `random.seed(seed)` and `choose()` calls
`random.below(WSUM[c])`. It used to be a xorshift64 of this example's own — a
module-level `RS`, an `rs_next`, and an `rnd(n)` doing `(RS >>> 33) % n` — and
all three are gone.

The contract is unchanged and is all the solver ever asked of a generator:
deterministic given the seed, identical on every run, no float anywhere, and a
value in `0..n-1` for a frontier of `n` cells (`n < 1` answers 0, as it did
before and as `random.below` does). What is *not* unchanged is the stream, and
this example is unusually exposed to that, because the draw decides **which tile
each cell collapses to**: same seed, different picture. So `EXPECTED` moved, and
so did two things that were pinned by searching for a seed under the old stream:

- the **backtracking instance** `16x12 elbows seed 1` → **seed 2** (still exactly
  two contradictions and two rewinds; under the new stream seed 1 propagates to a
  single solution and would have left `t_backtrack`/`t_rewind` asserting nothing),
- the **budget instance** `16x16 elbows seed 1` → **seed 37** (seed 1 now solves in
  912 steps; `gate.conf`'s exit-4 clause depends on this one too).

Both were re-swept rather than remembered, and both the sweep and the reason are
written down at the constants (`BT_SEED`, `t_giveup`) and under "the search gives
up". The properties those instances stand for — *an instance exists that needs a
rewind and gets it*, *an instance exists that exhausts the budget*, *same seed
gives same picture* — are properties of the solver and all three are asserted
again; the specific `(size, seed)` pairs are properties of the generator and were
re-pinned.

### THE DETERMINISM RULE, stated once

> The cell of **lowest Shannon entropy** is collapsed, and among cells of
> **equal entropy** the one with the **LOWEST CELL INDEX** (row-major,
> `i = y*W + x`).

Equal entropy is the common case, not an edge case: at the start every cell has
the same population and the same sixteen tiles to choose from. The scan in
`wfc.pick()` runs in index order and keeps the first minimum, which is that rule;
the recorded entropy is the Q30 integer `wfc.entropy(mask)`, computed as
`log2(W) - (Σ w_t·log2 w_t)/W` from a 129-entry table of `log2` for small
integers. `--inject=4` breaks ties on the **last** index instead — still perfectly
deterministic, still wrong, and the battery catches it.

The tie-break is load-bearing and the battery says so out loud: on the 4x3
instance it decides **7 of 11** decisions, and a check that pins the rule without
counting the ties would not know whether it had tested anything.

### Why entropy, in integers

`log2` is a table, not a call. The weights are small integers (1..6) and their
sums top out at 37, so there are only 129 values to know and a table is exact to
one ulp — and **nothing in `wfc.y` divides two fixed-point numbers**. That is
deliberate: `a / b` on two Q30 values returns their *ratio* rather than a scaled
quotient (ORCHESTRATOR.md 2.4a), the trap that cost another example in this
campaign six defects, and the one division here is by the plain integer `W`.
The only Q30→integer conversion in the program goes through `fx.to_int`, which is
the one place `fx.y` earns its keep (tinting the undecided cells by entropy).

### The two traps this algorithm walks into

**No `break`, no `continue`** — both are undefined names (ORCHESTRATOR.md 2.9).
`propagate()` and `solve()` use a guard flag with an explicit terminal
assignment; `pick()` and `choose_r()` wrap their bodies in a positive condition
(`if (CNT[i] > 1) { … }`). A propagation loop that has to *stop* when nothing
changed is exactly the shape that wants `break` and the shape that gets it
wrong: an early version tested `nm != MASK[j]` and stopped there, which is
single-pass propagation and looks correct on small inputs.

**A deterministic tie-break** — asserted, not assumed: `check.y` drives the
solver one event at a time and, at every decision, recomputes the minimum-entropy
open cell from the live masks and requires that it is the cell the solver chose.
Getting this check wrong was instructive three times over; see "What the battery
caught" below.

## What to look at

- **`EXPECTED`** — the golden run: a header, the solve's counters, three frames
  of the search, and the finished grid. 2101 bytes, byte-identical over three
  runs.
- **`frame 1/3`** — the frames show the propagation front: cells the search has
  not reached are drawn by entropy bucket (`: = ~ #`, none of which is a tile
  character), and the one that collapses next is the palest.
- **the finished grid** — a network of closed loops; `network: … in 19 closed
  components` says how many.
- **`--tiles loop --no-tty --frames 4`** — every cell busy, no background at all:
  107 collapses for 108 cells, 108 cells carrying a socket in 5 closed
  components.
- **`--tiles lines --size 12x9 --no-tty`** — and the interesting degenerate end:
  `0 collapses`. A straight tile has a north socket, so no top-row cell can be
  one; the corners force `empty`; that propagates around the whole boundary and
  then inward, and the interior loses both straights the same way. The tile set
  is decided entirely by the boundary, which is a *correct* answer from a solver
  that never chose a cell, not a degenerate one — and it is the clearest
  demonstration that propagation, not collapse, is doing the work here.
- **`--tiles straights --size 2x2 --no-tty`** — the unsatisfiable instance:
  a message on stderr and exit 3.
- **`--tiles elbows --size 16x16 --seed 37 --no-tty`** — the search gives up at
  the budget: a message on stderr and exit 4. (The `--seed 37` is load-bearing;
  see "the search gives up" above for why seed 1 no longer does this.)
- **`--check`** — the property battery, its actual output below.
- **`golden/interactive.txt`** — a pty capture of the terminal path, escape
  sequences and all.
- **`oracle.py`** — the same puzzle in Python, enumerating every solution of the
  small instances so that check.y's enumerator has a second opinion.

## The property battery (`--check`)

No reference file is involved. Every expectation is either worked out by hand
(derivations below), published in the tile table, or computed a second way by a
*different* algorithm. **152 checks, 0 failed**, and then the sweep: **17
deliberate defects injected, 17 caught, 0 missed.**

### 1. The finished grid against the socket rule — the real oracle

For seven instances (1x1, 2x2 ×2, 3x2, 4x3, 12x8 ×2, 6x4 loop, 16x12 elbows),
checked on the completed image with `check.y`'s **own** copy of the socket bits —
parsed out of the tile *names* (`elbow-NE` → N|E, `cross-NESW` → all four,
`empty` → none) and compared against `tiles.SOCK` — plus:

- every cell holds **exactly one** tile (an open cell is not a solution; an
  **empty** mask is a contradiction the search failed to report),
- every adjacent pair agrees on the shared edge, in both directions,
- no socket faces off the grid,
- and the anti-vacuous guard: **the count of pairs examined is not zero**, so a
  grid with no adjacent pairs cannot pass as "no violations", and the number of
  socket-carrying cells is asserted to be at least what the caller expects — an
  all-empty grid cannot pass as "no violations" either.

A propagation bug that still emits a self-consistent grid slips past anything
that watches the process and is caught here. That is the whole reason this
exists: `cube` passed all eight gate items while rendering filled wedges.

### 2. An exhaustive enumerator

`check.y` walks **every** assignment of a small grid to available tiles that
satisfies the raw rule — plain depth-first backtracking, no propagation, no
entropy, no propagation-derived pruning — and uses it three ways:

- **the number of solutions, against hand-derived counts** (derivations below);
- **every solution lies inside the masks propagation reached** (3x2 all: 128
  solutions; 3x3 loop: 969) — a propagation that deletes a tile some valid grid
  needs is unsound, and that is the one property a hand-count cannot give;
- **an instance the search calls unsatisfiable really has none**: `straights` on
  2x2, `loop` on 1x1, `cross` on 3x2, and mask 14 on 3x3 all enumerate to zero
  solutions.

The walk reports whether it reached its limit, so a truncated count can never
pass for a total. `oracle.py` enumerates the same instances in Python and must
agree; it does.

### 3. The bookkeeping and the rule

- `CNT` and `WSUM` equal what `MASK` says, bit by bit, after propagation **and
  after backtracking restored masks from the log**;
- no tile with an off-grid socket is in any boundary cell's initial mask;
- the weighted draw is exactly weighted: over `r = 0..36` each of the sixteen
  tiles is drawn exactly its weight times (an exact statement, not a frequency
  over 200 runs), and two equal weights split their range 3/3 by tile index;
- `entropy` of 2 and of 4 equal-weight tiles is **exactly** 1 and 2 bits
  (1073741824 and 2147483648), of 5 equal-weight tiles exactly log2 5
  (2493151308), and of weights 6:1 exactly 635303810 — all checked against
  arithmetic that did not come out of the table;
- entropy is **0 exactly on the 17 masks holding at most one tile**, over all
  65536 of them, and symmetric in its arguments over all 240 ordered pairs;
- the selection rule, at every decision of a step-by-step drive;
- a rewind restores **every** cell's mask **exactly** — the state immediately
  before the undone decision, compared cell by cell against this file's own
  snapshot;
- the same seed gives the same picture, a different seed a different picture, and
  a *different (wrong) tie-break* a different picture — so the picture depends on
  the rule and the determinism does not depend on anything else;
- the frame digest equals FNV-1a over the painted bytes, newlines included, and
  moves when one cell is perturbed;
- components counted by union-find and by flood fill agree, and every component
  has at least two cells;
- a full-size grid (64x64 = 4096 cells) solves inside the budget with no cell
  open and no violation.

### 4. Unsatisfiable, and giving up — three shapes

- **the initial domain is empty**: `straights` on 2x2. No available tile clears
  all four sides, so every cell of a 2x2 (all corners) starts empty. Propagation
  **cannot** detect this — a mask with nothing in it has nothing left to narrow —
  and a search that announced a solution here would be announcing four empty
  masks as a picture. Requires UNSAT, zero collapses, zero backtracks.
- **propagation finds it**: mask 14 = {`end-N`, `end-E`, `end-S`} on 3x3. Every
  initial domain is non-empty (the bottom-right corner has exactly `end-N`), and
  the contradiction takes three propagation steps: bottom-right is `end-N`, so the
  cell above it needs N, so that cell is `end-N`, so the top-right corner — which
  is on the east edge and cannot be `end-E` — needs N and has none.
- **the search gives up**: 16x16 `elbows`, **seed 37**, contradicts itself 88 473
  times and stops at the budget with `R_BUDGET` and 4 000 002 steps. Exit 4, a
  message, no trap, no hang. This is the "must never hang" property made
  testable.

  The seed is 37 and was 1, and *why* is worth a paragraph of its own: which
  seeds exhaust the budget is a property of the **generator**, and the generator
  is std's splitmix64 now (it used to be a xorshift64 in `wfc.y`).  16x16 seed 1
  propagates to a solution in 912 steps under the new stream, so without the
  re-sweep this section and `gate.conf`'s exit-4 clause would have been testing
  nothing while still looking rigorous.  A sweep of 16x16 seeds 1..37 found 37:
  88 559 collapses, 88 473 contradictions and backtracks, 4 000 002 steps, exit 4.
  `check.y`'s `t_giveup()` names the same instance and says the same thing.

### The hand-derived counts

| instance | solutions | derivation |
|---|---|---|
| 1x1 `all` | **1** | the cell is on all four edges, so only a tile with all four sockets clear survives: `empty` |
| 3x2 `lines` | **1** | the four corners must be `empty` (a straight cannot clear both its boundary sides), so the two middle cells have E and W matched against empties, and the bottom one cannot be NS because it is on the bottom edge |
| 2x2 `elbows` | **2** | the top-left corner is `empty` or `elbow-ES`; `elbow-ES` has exactly one non-empty completion — the ring `elbow-ES elbow-SW / elbow-NE elbow-WN` |
| 2x1 `ends` | **2** | both empty, or `end-E end-W` |
| 2x2 `ends` | **7** | all empty; two horizontal pairs; two vertical pairs; two corner pinwheels; and the one with all four cells as ends |

The check asserts both the count **and**, for 2x2 `elbows`, that the search's own
answer is one of the two hand-listed solutions — a wrong answer cannot hide
behind a right count.

### The injected defects

`--check` puts each of the seventeen defects below in force and **requires the
battery to fail**. Each lives behind an `if (INJECT == n)` in `wfc.y` or
`tiles.y`, is one readable line, and can be run by hand:

    ./wavefunction --check --inject 9     # must FAIL, and say which check

| n | the defect | first check to see it |
|---|---|---|
| 1 | propagation skips the south step | the 4x3 grid no longer has its sockets |
| 2 | propagation unions instead of intersecting | 2x2 elbows stops solving |
| 3 | propagation ignores a mask that emptied | mask 14 on 3x3 |
| 4 | the tie-break is the **last** index | the selection rule |
| 5 | pick ignores entropy, takes the first open cell | the selection rule |
| 6 | the draw counts tiles instead of weight | the exact draw distribution |
| 7 | the rewind does not restore the mask | the rewind's exact state |
| 8 | the rewind's mark is one entry too far forward | the rewind's exact state |
| 9 | entropy reads the log2 table one row off | entropy of equal weights |
| 10 | `CNT` is one too high on every cell | `CNT` vs `MASK` |
| 11 | the boundary answers for the opposite side | off-grid sockets in the initial masks |
| 12 | the north boundary is not applied | off-grid sockets in the initial masks |
| 13 | the south direction reads as east | the 16x12 elbows contradiction count |
| 14 | a contradiction is fatal: no backtracking | 16x12 elbows stops solving |
| 15 | `HENT` carries a stale value | the recorded entropy |
| 16 | the search calls itself done after one decision | 2x2 ends stops collapsing |
| 17 | propagation does not re-queue a cell it changed | the 16x12 elbows grid disagrees |

Each injected run happens in a **forked child**, because some defects are worse
than wrong: injection 8 in an earlier form drove the undo index negative, and a
trap prints to stdout and kills the process, which took the sweep down with it and
left the report saying nothing after defect 7.

**One mutation was proved equivalent rather than dropped.** The first version of
injection 11 ignored `avail` when building the compatibility tables — which is
*provably* invisible: every cell's mask is a subset of `avail` (the initial
domains are masked by it and propagation only intersects), so tiles outside the
subset can never be a *source* of the union, and anything they add is removed by
the intersection with the neighbour's mask. It was replaced with a boundary defect
that is observable, and the proof is recorded here rather than in a comment that
nobody reads.

**Two earlier versions of injection 8 were also invisible, and the reason is
worth keeping.** `wfc.y` reports, at every rewind, whether the entry just below
the mark was still in force (`XTRA_DIFF`) or already undone (`XTRA_SAME`). On
this instance it is *still in force* both times — but it belongs to a cell the
undone decision also touched, so the rewind loop's own restore of that cell
overwrote the damage. A mutation you cannot catch is usually one you have not
made visible. The check prints both counts rather than pinning them, because on
another instance they could legitimately go the other way.

## What the battery caught while it was being written

Every one of these is a real defect in this example, found by the battery, not by
reading the code:

1. **Four of the six `--tiles` masks were wrong** (85 for `{0,5,6}`, 1063 for
   `{0,7..10}`, 80 for `{5,6}`, 65409 for "everything but empty") — hand-written
   bitmasks that nothing else in the program would have noticed. Two of them
   turned a documented **unsatisfiable** instance into a satisfiable one: the
   flag still ran, it just solved something else. `t_subsets()` now derives each
   mask from the tile *names* and compares.
2. **The same masks were written twice.** Fixing the constants left the
   `SUBMASK` table carrying the old values, which is a second place for them to be
   wrong. The table is built from the constants now.
3. **`setup()` did not clear the worklist flags.** A cell still flagged from the
   previous solve refused to be queued, propagation never reached it, and the
   search returned a grid whose masks were not even mutually consistent — while
   the *first* solve, whose flags were clean, looked perfect. This is why the
   frames disagreed with the headline counters.
4. **The collapsed cell was never re-queued**, so a collapse was never applied to
   its neighbours: the search finished a grid of cells that disagreed, 20
   violations on a 4x3, and `audit` said so. Exactly the failure a golden file
   cannot see.
5. **A hand-rolled `opposite(d)` returned 2 for south** in two places, which
   made every *vertical* placement a contradiction while the horizontal case
   worked — 331 spurious backtracks and an all-empty 24x14 grid. It is now one
   function, `tiles.opposite()`, with the story in the comment above it.
6. **An empty initial domain was reported as a solution.** `pick()` treats a
   zero-tile mask as "not more than one tile", so `straights` on 2x2 announced a
   picture made of four empty masks. `setup()` counts them and the search refuses.
7. **A fixed `[long; 64]` in the battery overflowed** on the 12x8 instance — a
   runtime trap, on stdout, in the middle of the check.
8. **A check that compared a live number against an unwritten slot**: eleven
   comparisons of the minimum entropy against `EV_H[idx]` *before* the call that
   writes it. It failed loudly only because the value was non-zero; compared the
   other way round it would have passed vacuously.
9. **A check that compared the state at the wrong point**: the decision is made
   from the **fixpoint**, not from the state before the event, so five of eleven
   decisions looked wrong on a solver that was right.
10. **A check that asserted a property false of legal grids**: "no cell carries a
    single socket" — two end tiles facing each other are a legal two-cell
    component, and `2x2 ends` has such a solution.
11. **A digest of the cells without the newlines**, so the frame digest was not
    the digest of what `paint()` writes.
12. **A check that compared a function with itself** (`c_components()` against
    `wfc_components()`, which called it). The campaign's worst failure mode,
    written by accident and caught by reading the diff.

## Numbers

Measured on this machine, inside the campaign's 3.5 GiB cap, with the pinned
compiler.

| what | number |
|---|---|
| 24x14 (`--frames 3 --no-tty --seed 1`) | 335 collapses, 0 backtracks, 1640 propagation steps, 969 undo entries, **480–800 µs** over five runs (a shared machine; the count is exact, the wall clock is not) |
| 12x8, seed 1 | 95 collapses, 458 steps, **125–260 µs**; 172 adjacent pairs, 0 disagreements, 0 off-grid, 79 of 96 cells carry a socket |
| 64x64 (4096 cells) | 4095 collapses, 20 350 steps, **30 ms**; no cell open, audit clean |
| 16x12 `elbows`, **seed 2** | 69 decisions, **2 contradictions, 2 rewinds**, 783 steps |
| 16x16 `elbows`, **seed 37** | **gives up**: 88 473 contradictions, 4 000 002 steps, 510 ms |
| `--soak 200` (336 cells) | 93 ms for 200 solves, 465 µs each, **heap delta 0 bytes** |
| `--soak 5` at 64x64 | 150 ms, **heap delta 0 bytes** |
| interactive, 49x22 | 27 frames, 7022 bytes of ANSI, **heap delta 0 bytes** (the frame count is whatever the pty capture happened to paint before `q`; it is not a measurement) |

Zero allocation is not an aspiration here, it is measured three ways: 200 solves
of the golden instance, 5 solves of a 4096-cell instance, and 27 rendered frames
all report a heap delta of **0**. The solver's state is module-level fixed arrays
and nothing on any loop allocates: the union of two fixed arrays is allocated
once, the queue and the undo log are sized at compile time, and every byte of
output goes through one `[byte; 262144]` sink and a single `write(2)`.

**The quadratic audit, done rather than eyeballed** (`-S`, then count
`call y_str_app` — the discarded in-place append — against `call y_str_cat` —
the value-used exact-size copy):

    wfc.y          no string appends at all
    sink.y         no string appends at all
    wavefunction.y no string appends at all
    tiles.y        no string appends at all

Every `y_str_cat` in the binary is in `check.y` building a check *name*, or in
`args`. There is no `str` on the solve path, the render path or the golden
path at all, so there is nothing there to be quadratic. (A note for the next
example: `print()` is `println` — it appends a newline to every argument — which
is why a 24-cell row printed a character at a time comes out as 24 one-character
*lines*. That is what `sink.y` exists for.)

## The files

| file | what |
|---|---|
| `wavefunction.y` | the CLI, the two painters, the flood fill, the interactive loop |
| `wfc.y` | the solver: setup, propagate, pick, collapse, rewind, budget |
| `tiles.y` | the sixteen tiles, the socket rule, the two projection tables |
| `check.y` | the property battery and the defect sweep |
| `sink.y` | the text path: one fixed byte buffer, one `write(2)` |
| `oracle.py` | the same puzzle in Python: solution counts and the Q30 anchors |
| `pty_check.py` | drives the terminal path through a real pty; `--save PATH` writes the raw bytes |
| `golden/interactive.txt` | that capture, escape sequences included. A **capture, not a golden**: nothing compares it byte for byte, and it was re-taken when the solver's generator moved to std's `random` and the picture it paints changed |
| `EXPECTED` | the golden run's stdout, 2101 bytes |
| `gate.conf` | `build=`, `run=`, `check=` (the battery **and** the two exit codes) |

Vendored from `examples/_toolkit/`, byte-identical, never edited:

| file | sha256 |
|---|---|
| `fx.y` | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` |

## Language workarounds, all of them visible in the code

| what | where | why |
|---|---|---|
| no `break`, no `continue` | `wfc.propagate`, `wfc.solve` (guard flag), `wfc.pick`, `wfc.choose_r` (positive condition) | ORCHESTRATOR.md 2.9 — both are undefined names |
| no `sort` | not needed: the selection rule *is* an ordered scan, and `check.y` sorts nothing | §2.8 |
| fixed `[T; N]` is not `[T]` | `check.y` keeps its own buffers rather than passing `wfc`'s | filed: SUGGESTIONS.md 19 |
| `print()` is `println` | `sink.y` | one byte buffer and one `write(2)` instead |
| `term.read_key_timeout(0)` | `wavefunction.interactive` | a 1..99 ms poll rounds up to 100 ms (VTIME counts deciseconds) and reports ~0.6 fps with a stuck frame counter |
| `winsize()` by ioctl | not needed — the size is read once, before the loop | `term.size()` returns a fresh record per call (~40 B) and the loop is the frame loop |
| tui's `emit_num` drops a zero digit | `wavefunction.safe_ch()` | filed: BUGS.md, "tui's emit_num drops a zero digit" — a channel of 205 reaches the terminal as 25 |
| tui's CUP has the same bug | the interactive grid is capped at 49x23 | column 101 would be emitted as 11; 1..99 is the range `emit_num` gets right |
| `>>` vs `>>>` | `sink.sink_hex16`, `sink.sink_q30` | `>>>` is logical; it is used only where zero-extension is wanted and only on values that are non-negative by construction. (The solver's own use of `>>>` was `wfc.rs_next`, the xorshift64 that std's `random` replaced — see "The generator".) |
| a fixed array in a loop body | every table in `tiles.y` and `wfc.y` is module-level | an array literal in a loop body allocates 64 bytes an iteration |
| `str + byte` | never written | `s[i]` on a `str` is a byte and `str + byte` segfaults; nothing here concatenates one |
| `main()`'s return is not the exit status | `def main() -> long { … }; exit(main())` | ORCHESTRATOR.md — `main();` exits 0 even when main "returned" 1 |
| `import` resolution | everything vendored or in the folder | gate item 5 builds the folder alone |

Nothing here needed a compiler patch, and **no compiler bug was found**: the
pinned compiler compiled all ten files with zero warnings and behaved correctly
throughout, including the fixed-array subtyping diagnostic that became
suggestion 19.

## Exit codes

| code | meaning |
|---|---|
| 0 | fine |
| 1 | a bad flag or a bad argument (message on stderr) |
| 2 | a usage error from the flag parser itself |
| 3 | the instance is **unsatisfiable** and the search proved it |
| 4 | the step budget ran out — no answer either way |
| 5 | `--check` found something wrong |

Every one of those paths was run and produces a message on stderr, a non-zero
status and **no runtime trap**; gate item 3 plus `gate.conf`'s `check=` line
(which asserts 3 and 4 through a real process) is what holds them there.

## Keys, interactive

`space` one event · `a` auto-run · `n` reseed and solve again · `t` toggle the
entropy tint on the undecided cells · `q` or Escape quit. The interactive path
**plays back the recorded solve** rather than solving in front of the reader,
deliberately: the picture on the terminal is then the same bytes `EXPECTED`
holds, and a frame counter that disagreed with the golden would be impossible.
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
