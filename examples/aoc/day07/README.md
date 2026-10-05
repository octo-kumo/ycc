# Advent of Code 2025 — day 7, "Laboratories" — in Y

`day07.y` solves both parts of AoC 2025 day 7 from this folder's own copy of
the puzzle input, prints both answers, and ships a property battery that fails
if the logic is wrong.

```
cd examples/aoc/day07
../../../refs/ycc.ref day07.y -o day07     # build (three .., not four)
./day07                                     # both answers
./day07 --check                             # the property battery
./day07 --render example.txt                # draw the beams, for looking at
./day07 --help
```

**Pinned compiler:** `refs/ycc.ref`, sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`.
Every number below was produced by that binary. The pin moves; if `EXPECTED`
stops reproducing under a new one, rebuild, re-run and record the new sha —
never fudge the golden file.

## The answers

| | |
|---|---|
| **part 1** (times the beam is split) | **1660** |
| **part 2** (distinct tachyon timelines) | **305999729392659** |

Both are printed by `./day07` and are in `EXPECTED`. The manifold is 142 rows
of exactly 141 columns — 1761 splitters, the source on row 0 at column 70 — and
every row is the same width, so the ragged-row question below does not arise
for this input (but is handled, and tested).

## The puzzle, in my own words

A *tachyon manifold* is drawn as a rectangular grid of `.` (empty space) and
`^` (splitters), with one `S` where a beam enters. Beams only ever travel
**downwards**. They pass through `.` freely. A beam that reaches a `^` is
stopped there, and instead two new beams set off, one from the cell
immediately to the splitter's left and one from the cell immediately to its
right; from there they fall like any other beam. Beams that leave the grid
through a wall, or fall out of the bottom, are gone.

Two things the statement is explicit about, and which the whole puzzle turns
on:

- several beams can arrive in the **same column**, and then they are **one**
  beam again. The worked example draws two splitters "both dumping tachyons
  into the same place between them" and counts three beams, not four.
- a newborn beam is drawn on its splitter's **own row**, one cell to each
  side — the statement's third diagram is `......|^|......`.

**Part 1 asks:** how many times, over the whole fall, is a beam split?
**Part 2 asks:** how many distinct timelines does a *single* particle end up
on, when at every split it takes **both** the left and the right path (the
"many-worlds" reading: time itself splits).

## Where part 2 came from, and how confident to be

The day 7 statement page is login-gated after part 1 — an unauthenticated
`https://adventofcode.com/2025/day/7` returns part 1, one `<h2>`, then a login
prompt. So **part 2's wording is not from Advent of Code.** It comes from two
independent public write-ups that agree:

- <https://rarewood.dev/aoc-2025/day-7> — "How many timelines exist at the
  end?"; tracks particle *counts* per column rather than a set of positions.
- <https://scalacenter.github.io/scala-advent-of-code/2025/puzzles/day07/> —
  "we count all the possible timelines (paths) a tachyon can take".
- <https://notes.club/tylerj/aoc/lib/advent_of_code/2025/day-07> — a Livebook
  write-up that reproduces part 2's wording (its author was logged in) and
  states the answer for the statement's own example: **40**.

I am not quoting the statement's prose here; the rule above is my summary of
what those three pages say.

**Anchor tier reached: 1 (external), for both parts.**

| anchor | value | published by |
|---|---|---|
| part 1 on the statement's example | 21 | the AoC statement itself |
| part 2 on the statement's example | 40 | the notes.club write-up above |
| the beam model | the statement's final 16-line picture | the AoC statement itself |

Both anchors are asserted by `--check`, and so is a byte-for-byte
reproduction of the statement's published final picture (16 lines of the
example manifold with every beam drawn in) — see "the picture anchor" below.
The real-input answers come from my own solver; the anchors only validate the
*interpretation*, which is exactly what they are for.

## Layout

| file | what it is |
|---|---|
| `day07.y` | the whole program: solver, renderer, property battery |
| `input.txt` | this folder's copy of the puzzle input (gitignored, below) |
| `example.txt` | the statement's 16x15 example manifold (public, tiny) |
| `EXPECTED` | the golden stdout of `./day07` |
| `gate.conf` | `build=`, `run=`, `check=` for `examples/gate.py` |
| `inject.sh` | 19 injected defects; each one must make `--check` fail |
| `.gitignore` | keeps `input.txt` out of git |

`input.txt` is per-account personal data. It is copied here so the folder is
self-contained and builds with every other day deleted; `.gitignore` keeps it
out of the repository, and no session cookie appears in any file here.

**Self-contained:** one `.y` file, `import fs` (a std unit shipped with the
compiler), no cross-day import, no shared mutable state. Deleting every other
folder under `examples/aoc/` changes nothing.

**No vendored toolkit.** This example needs no `fx.y` and none of the std
units: it reads a file, prints lines and exits, with no
terminal, no clock, no trigonometry and no randomness. So there are no
vendored-file shas to record. (Nothing is drawn to a framebuffer either;
`--render` builds 16 or 142 ordinary strings and prints them.)

## What to look at

- `count_splits` — part 1: a **set of columns** per row, with a stamp array so
  "is this column already in the set" is O(1) and needs no clearing per row.
- `count_paths` — part 2: a **count per column**, accumulating, because two
  beams in one column are two particles with two pasts.
- `analyse` — the one entry point. `./day07` prints from it and `--check`
  asserts about it, so a defect injected there is genuinely injected
  (injection 15 does exactly that).
- `render_into` + `splits_by_render` — the statement's own picture, and part
  1 re-derived from it by counting glyphs.
- `run_exhaustive` — every manifold up to 3 rows by 4 columns.
- `probes_run_check` — five perturbations of the real input, each with an
  answer worked out in advance.

## Complexity and cost

Both sweeps are one pass over the grid, `O(rows x width)`, with the inner loop
touching one fixed 512-entry array. No allocation at all happens inside them:
the arrays are module-level `[long; 512]` scratch, reused by every call, which
matters because Y's heap is an arena and nothing is ever freed.

- `./day07` on the real input: **under 10 ms** wall clock, 2.0 MB maximum RSS.
- `./day07 --check` (60 assertions plus 28 385 enumerated manifolds):
  **~50 ms**, 64 MB maximum RSS, well inside the 3.5 GB campaign cap.

## The property check: `./day07 --check`

60 assertions, no reference file anywhere in it. Its output is the report at
the bottom of this section.

### 1. Hand-computed micro-cases

Each expectation is worked out here, so a reader can check the arithmetic
without running anything. `part 1` counts splits with coincident beams merged;
`part 2` counts each particle separately.

| # | grid | part 1 | part 2 | the arithmetic |
|---|---|---|---|---|
| a | `S` / `.` | 0 | 1 | nothing to split; the single path falls straight out |
| b | `S` / `^` | 1 | 2 | one column wide: the splitter's children are at −1 and 1, and **both are outside a 1-wide manifold**, so both timelines leave at once: 1 + 1 = 2 |
| c | `S....` / `^....` / `.....` | 1 | 2 | the splitter sits on the left wall; its left child leaves, its right child at column 1 falls out of the bottom: 1 + 1 = 2 |
| d | `...S...` / `.....` / `...^.^.` / `.....` / `..^.^..` / `.....` | 3 | 4 | splits at (2,3), (4,2), (4,4) → 3. Paths: the beam splits at row 2 (2 particles), and each of the row-4 splitters adds one more → 1 + 3 = 4. Note column 3 ends the fall holding **two** particles and part 1 still counts 3 beams, not 4 |
| e | d with three blank rows between the splitter rows | 3 | 4 | a row with no splitter cannot change the beam set, so blank rows are inert |
| f | c with **no trailing newline** | 1 | 2 | the last line is still a line |
| g | c with **CRLF** endings | 1 | 2 | the width is the text's, 5 — not 6 |
| h | `.S.` / `.^.` / `..^.` / `..` | 2 | 3 | width 4 from the longest row; the short last row is empty space. Splits at (1,1) and (2,2) → 2; the beam reaches column 3, which the first row does not have. 1 + 2 = 3 |
| i | h without the short row | 2 | 3 | the same, to isolate the ragged row |
| j | `S..` / `^..` / `.^.` | 2 | 3 | splitter on the wall (its left child leaves), then a splitter under the surviving beam: 2 splits, and of the three timelines one left early → **3, not a power of two** |
| k | `.S.` / `.^.` / `.^.` | 1 | 2 | both newborn beams pass either side of the splitter below, which is never hit |
| l | `S` / `^` / `^` | 1 | 2 | after the first split both children have left, so the second splitter is never reached |
| m | `.S...` / `.^...` / `^.^..` / `.^...` | 4 | 6 | **the case the rest of the battery cannot reach.** Splits at (1,1), (2,0), (2,2) and (3,1) → 4. The splitters at row 2 both dump into column 1, so at row 3 there is one *beam* there but **two** particles: 1 + (1 + 2 + 2) = 6. Needs four rows, so no grid three rows tall can show it |

### 2. The statement's example, and the picture anchor

`EX0` is the statement's own 16x15 manifold and `EXPIC0` is the final picture
the statement prints for it. Both are embedded in `day07.y` (they are the
puzzle's own data, and they are what makes the anchors external).

- part 1 = **21**, the value the statement publishes — asserted.
- part 2 = **40**, the value the notes.club write-up publishes — asserted.
- `render_into(EX0)` reproduces **all 16 lines of `EXPIC0` byte for byte**,
  including the newborn beams drawn on their splitter's own row
  (`......|^|......`, `.....|^|^|.....`, …). That is a stronger anchor than the
  number: it pins *where* every beam is on every row, not just a total.

This is where the model stopped being a guess. An early version of the
renderer stamped newborn beams in the same pass that propagated them, which
drew every beam one row late and matched the number 21 anyway; only the
picture comparison caught it.

### 3. Independent cross-checks

Every number production produces is re-derived by a method written
independently of it. All of them are reached **through `analyse`**, the same
entry point `./day07` prints from — none of them replaces it, and none of them
re-assembles the production pipeline, so a defect in production shows up as a
disagreement rather than being quietly agreed with.

| quantity | production | independent methods |
|---|---|---|
| part 1 | `count_splits`, a per-row column **set** with a stamp array | (a) `splits_by_reach`, a per-**cell** reachability bitmap rolled through two rows — no set, no list, no dedup stamp; (b) `splits_by_render`, which draws the picture and counts `^` cells that have a beam directly above |
| part 2 | `count_paths`, a per-row count per column, pushing | (a) `paths_rec`, a **top-down memoised recursion** (pull) that returns 1 on leaving the manifold; (b) `paths_pull`, a **bottom-up rolling sweep** over `below[r][c]`, the reverse direction of production; (c) `paths_exhaustive`, a recursion with **no memo at all** that walks every path to its end and counts the leaves — the only method that is not dynamic programming, and the only one that literally enumerates |
| splits with multiplicity | `mult_splits`, pushing | `splits_rec_mult`, the pull recursion again |

Two of these earned their keep immediately. `paths_pull` first omitted a
child that leaves through a wall, and the exhaustive sweep caught it on
**4750 of 28 385 grids** — a beam which exits the side is still a completed
path. `splits_by_render` first treated the source cell as empty space, because
the picture draws the letter `S` there, and missed every splitter in the
source's own column: **1258 grids**. Both were bugs in the *check*, not in the
solver, and both are fixed.

### 4. The whole state space, not a sample

`run_exhaustive` builds **every** manifold from 1 to 3 rows and 1 to 4 columns
— every placement of `S`, every filling of every other cell with `.` or `^` —
**28 385 grids**, and asserts on each that production agrees with
`splits_by_reach`, `paths_rec`, `paths_pull`, `1 + mult_splits`,
`splits_rec_mult`, the invariants below, and (where affordable) a brute-force
walk of every path. 0 mismatches.

The renderer is compared only on the 6747 grids whose splitters are never
**adjacent**, which is the only case the statement's picture defines at all
(see "what the statement leaves undefined" below); the other 21 638 are
counted and reported rather than quietly passed over.

### 5. Invariants

- `0 <= part 1 <= ` the number of `^` cells in the grid (1660 ≤ 1761). A beam
  visits a column once, so no splitter can be hit twice. 101 splitters in this
  manifold are never hit.
- `part 1 <= ` splits counted **with multiplicity** (1660 ≤ 305999729392658):
  merging can only lose counts.
- `part 2 >= 1 + part 1`. The particle count never falls and rises by exactly
  one per split, so `part 2 == 1 + ` multiplicity splits ≥ `1 + part 1`.
- **`part 2 == 1 + ` splits with multiplicity** — a conservation identity, and
  a fourth opinion on part 2 that is derived rather than simulated.
- The number of distinct beams in any row is at most the width (89 ≤ 141 here).
- `part 2 < 2^62`, so it fits a `long` with room to spare.
- The rightmost beam stays inside the grid.
- Every cell of the input is `.`, `^` or `S`; the smallest horizontal gap
  between two splitters in a row is 2.

### 6. Five perturbations of the real input

An answer is one integer, so the battery has to be sensitive to the *input*
as well as to the code. Each of these is re-solved through `analyse` and
compared with an answer worked out in advance:

1. **Blank out every splitter** → part 1 = 0, part 2 = 1, exactly. The
   sharpest of the five: it fails unless both answers are driven by the
   splitters and by nothing else.
2. **Append one empty row** → unchanged. A row with no splitter cannot change
   the beam set.
3. **Append one empty column** → unchanged, and the precondition is asserted
   too (there is no splitter in column 140; the rightmost beam does reach
   column 140 and simply carries on).
4. **Truncate the manifold at half height** (71 rows) → part 1 1660 → 434,
   part 2 → 43 469 659. The beam's evolution is unchanged up to the cut, so
   neither answer can *grow*; both must shrink.
5. **Move the splitter under the source one row earlier** → unchanged, and
   this one is worth reading twice. The beam then splits at row 1 instead of
   row 2, and the splitter it used to hit is never reached, so the total is
   identical — *because the row in between holds no other splitter*, which is
   asserted as a precondition rather than assumed. It is the probe I wrote
   first, with the expectation `part 1 + 1, part 2 doubled`; the check
   disagreed with me, the check was right, and the property turned out to be
   more interesting than the probe.

### 7. Error paths

No input, however malformed, traps: every rejection prints a message to stderr
and exits non-zero. Exercised: no `S`; an empty file; a file of blank lines; a
file of bare carriage returns; a manifold of splitters with no `S`; a manifold
wider than the 512-column limit. Argument handling is the same: `--help`
prints and exits 0, an unknown `--option` and a missing `--input` argument
print and exit 1, and a second input file is refused.

### 8. Defect injection: 19 injected, 19 caught

`./inject.sh` copies the source, applies one `sed` mutation, rebuilds with the
pinned compiler and **requires `--check` to fail**. The source is never edited.
A runtime trap counts as caught — a trap is a defect the check can only report
by dying.

| # | injected | caught by |
|---|---|---|
| 1 | `count_splits`: a split is never counted | 19 FAILs, first: the published anchor 21 |
| 2 | `count_splits`: the beam set keeps duplicates | 1 FAIL: micro m — the only case that needs four rows |
| 3 | `count_splits`: stamp array reset to a live row index | 19 FAILs, first: the published anchor 21 |
| 4 | `count_splits`: beams pass through splitters | 19 FAILs, first: the published anchor 21 |
| 5 | `count_paths`: a splitter stops splitting | 24 FAILs, first: part 2 vs recursion (1 vs 40) |
| 6 | `count_paths`: the left child overwrites instead of adding | 14 FAILs, first: part 2 vs recursion (12 vs 40) |
| 7 | `count_paths`: the first row under the source is skipped | 9 FAILs, first: micro b |
| 8 | `count_paths`: a beam leaving through a wall is not a path | 8 FAILs, first: micro b |
| 9 | `count_paths`: the source starts two particles | 23 FAILs, first: part 2 vs recursion (80 vs 40) |
| 10 | `parse_grid`: width from the first row, not the longest | trap: `unwrap of none` |
| 11 | `parse_grid`: a final line without a newline is dropped | 1 FAIL: micro f |
| 12 | `parse_grid`: the carriage return is not stripped | 1 FAIL: the CRLF width assertion |
| 13 | `parse_grid`: short rows are not padded | trap: `index out of bounds` |
| 14 | `is_split`: every empty cell counts as a splitter | 31 FAILs, first: the published anchor 21 |
| 15 | `analyse`: part 2 wired to the part-1 sweep | 26 FAILs, first: part 2 vs recursion (21 vs 40) |
| 16 | the statement-published anchor 21 edited to 22 | 1 FAIL: the anchor itself |
| 17 | micro j's expected part 2 edited from 3 to 4 | 1 FAIL: micro j |
| 18 | `probe_blank`: the splitters are no longer blanked out | 1 FAIL: the blanking probe |
| 19 | the `part 2 >= 1 + part 1` oracle tightened to an equality | 1 FAIL: the identity assertion |

Four of these were **missed on the first run**, and each miss was a real gap
in the battery rather than a bad injection — that is why the matrix above is
worth reading:

- **#2 was missed** because no grid three rows tall can produce a beam set
  with a duplicate in it, so the exhaustive sweep agreed with the broken
  sweep, and the 16-row statement example happens not to have the pattern
  either. Fixed by adding micro m, the four-row case.
- **#12 was missed** because stripping a carriage return changes only the
  *width*, never an answer: the CR becomes one extra inert column. Fixed by
  asserting the parsed width on CRLF input, which is observable output.
- **#19 was missed** because the mutation *weakened* an assertion, and a
  weakened assertion cannot fail anything. Replaced with a mutation that
  *tightens* one, which shows the oracle actually fires.
- An earlier #8 was a stale `sed` that matched nothing (the statement it
  replaced has no trailing semicolon); `inject.sh` reports that as `NOTHING`
  rather than counting it as a pass.

## What the statement leaves undefined, and what I do about it

Two beams meeting in one column is the case the statement *does* define, and
it is the one both my solvers implement differently — part 1 merges, part 2
does not.

**Adjacent splitters are not defined by anything.** A newborn beam lands on
the splitter's own row, one cell to the side; if a splitter sat there, the
beam would meet it, split, and one of *its* children would land back on the
first splitter, forever. The statement's picture cannot draw that, and both
public write-ups ignore it. My reading — the one both write-ups implement, and
the only one that terminates — is that a newborn beam is checked against the
**next** row, so a beam can pass *through* the cell a splitter is drawn in.
This is a non-issue for the real input and for the statement's example: both
have a smallest horizontal gap of exactly 2, which is asserted. It only shows
up in the 21 638 enumerated grids that have adjacent splitters, and the
renderer is simply not compared on those.

## Compiler notes

Nothing here needed a compiler workaround except one, and it is already
filed. The full list of traps I hit that were *mine*, not the compiler's:

- A stamp array shared between calls must be reset to a value no live index
  can take. Resetting it to 0 and starting the sweep at row 0 makes the first
  beam compare `stamp == row`, get dropped, and print `0 splits` — which
  reads as an answer, not as a bug. (injection 3 pins this.)
- Newborn beams must be stamped *before* the row is drawn, not in the same
  pass that propagates them, or every beam is drawn one row late — and the
  split **count** still comes out right.
- An empty `[str]` is not a scratch buffer: `pic[r] = line` on it traps. Grow
  it once with `while (len(pic) < g.h) { pic += "" }`.
- A hand-worked expectation is wrong at least as often as the code is. Four of
  the numbers I asserted by hand were wrong on the first run (micro h, i, j and
  the first version of probe 5); the battery caught every one, and in each
  case the code was right.

`chr()` is the only way I get a cell back into a string, because
`examples/BUGS.md`, *`str + byte` segfaults* (and its two follow-ups, *The
`str + byte` filing's `+=` workaround is now a compile error* and *`'+='
string` rejects a `byte` operand*) record that `str + byte` crashes and
`str += byte` does not compile. `probe_blank` rebuilds a row through
`chr(b)` for exactly that reason.

**Nothing was filed for this day.** I found no compiler bug: everything that
went wrong was a mistake of mine, listed above, and the two "bugs" my own
battery found were both in the battery. No new entry in `BUGS.md` or
`SUGGESTIONS.md`, and no renumbering.
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
