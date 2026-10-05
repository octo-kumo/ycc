# day12 — Advent of Code 2025, day 12 ("Christmas Tree Farm"), in Y

## What this is

The puzzle, in my own words: a cavern under the North Pole is full of
Christmas trees, and under each tree is a rectangular **region** measured in
unit cells. A short catalogue of **present shapes** is given, each drawn on a
small grid of `#` (part of the present) and `.` (not). Each region line lists
how many presents **of each shape** must go into that region. A present may be
rotated and flipped, must sit exactly on the grid, and two presents may not
share a cell — but the `.` holes inside a shape's diagram block nothing, so
shapes interlock.

- **part 1** — *how many of the regions can fit all the presents listed?*
- **part 2** — **there is none.** See "Where part 2 came from" below.

The program answers part 1 for the vendored input and prints both answers.

## Build and run

```sh
cd examples/aoc/day12
../../../refs/ycc.ref day12.y -o day12     # three levels up: day12 -> aoc -> examples -> root
./day12                                    # input.txt -> both answers   (the gate's run=)
./day12 --check                            # the property battery       (the gate's check=)
./day12 --inject 7                         # apply defect 7, say whether the battery notices
./day12 --help
./day12 some_other_input.txt               # any file in the same format
```

* **Pinned compiler**: `refs/ycc.ref`, sha256
  `e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`.
  The pin moves during the campaign; if the sha no longer matches, rebuild,
  re-run and record the new one. Never fake a match.
* **Toolkit**: **none vendored.** This example needs no `fx.y` / `term.y` /
  `fb.y` / `args.y` / `time.y`, so there is no toolkit revision or toolkit
  sha to record — it is a batch program: no terminal, no clock, no
  randomness, no threads.
* **Runtime**: 1.5 s for the real input (1000 regions, 103 656 presents
  placed and verified); `--check` takes 8.8 s. Heap is a handful of
  module-level `[long]` scratch arrays, grown once to the largest region
  (2500 cells) and reused — nothing is allocated per region except the
  witness record array, and the run stays far inside the 3.5 GiB cap.
* **Determinism**: no clock, no network, no terminal size, no randomness.
  The only order-sensitive choice — which of a shape's orientations the packer
  prefers — is a fixed generation order (mirror in {no, yes} outer, quarter
  turns 0..3 inner, first occurrence of a shape kept), never a set or map
  iteration order. `--check` re-solves the input three permuted ways to prove
  the answer cannot depend on the file's order.

## The input's real structure (this is not the day-NN grid convention)

`input.txt` is **1030 lines, two sections, and every line is accounted for**:

| lines | what |
|---|---|
| 1–30 | six shape blocks: a label line `N:`, then exactly 3 rows of `#`/`.`, then a blank line |
| 31–1030 | 1000 region lines `WxH: q0 q1 q2 q3 q4 q5` — six quantities, one per shape |

Nothing else appears: no comment lines, no `###` separators, no trailing
whitespace, no blank line inside a shape block. (A tolerant parser is better
than an exact one, so `day12.y` classifies each line instead: a line of only
`#`/`.` starts a shape diagram, a line of `digits 'x' digits ':' …` is a
region, `digits:` is a shape index it may ignore, and anything else is an
error naming the line number. Blank lines are skipped anywhere.)

The shapes in *this* input are **not** the statement's example shapes:

| index | diagram | cells | distinct orientations |
|---|---|---|---|
| 0 | `###`/`###`/`#..` | 7 | 8 |
| 1 | `###`/`##.`/`#..` | 6 | 4 |
| 2 | `###`/`..#`/`###` | 7 | 4 |
| 3 | `..#`/`.##`/`##.` | 5 | 4 |
| 4 | `###`/`.#.`/`###` | 7 | 2 |
| 5 | `###`/`##.`/`.##` | 7 | 8 |

All six are 3×3, and shape 4 has an **enclosed hole** (its centre cell is
walled in on all four sides), so every copy of it permanently wastes one cell.
That trap turns out to cost nothing here: with a slack of 26 %–37 % and at
most 77 copies of any shape, the hole never decides a region.

The regions are **35×35 to 50×50** (250 distinct sizes; both dimensions run
35…50). The six quantities are 11…77, so a region asks for 120–225 presents.
Counting cells: **454 of the 1000 regions ask for more cells than they have**
(over by 1 to 3 cells each), and the other 546 ask for 63 %–74 % of the
region — between 26 % and 37 % slack. The counts were not derived from
packings, so this input is not a "does a packing exist" corpus; it is an area
corpus with a constructive certificate attached.

## What to look at

1. **The answer** (`EXPECTED`): part 1 = **546**, part 2 = the epilogue.
2. **`decide()`** — the whole verdict for one region, in four lines of
   reasoning: area says no ⇒ no (a proof); a packing was built ⇒ yes (a proof);
   neither ⇒ *undecided*, never silently a "no".
3. **`witness_check()` / `mark_records()`** — the certificate. It does not
   trust the packer: it clears a second grid and rebuilds it from the four
   longs per present that the packer recorded, so a packer that *wrote* one
   placement and *recorded* another is caught.
4. **`turn_check()` and `flip_check()`** — the transposition involution and its
   companion (below).
5. **`exhaustive()`** — the complete search, and the one place where a subtle
   bug cost me real time: see "What the search has to get right" below.
6. The **micro-case witnesses** printed by `./day12 --check`: 14 tiny regions,
   each with the packing the greedy found drawn with letters, so a reader can
   check a 4×6 by eye.

## How the answer is exact (and why it does not need a complete search)

Fitting polyominoes into a rectangle is bin-packing feasibility: NP-hard, and
1000 instances of 200-odd pieces is far past what exhaustive search can do.
So the program does not try to solve it. It answers by a **sandwich**, one
half per direction, and `--check` verifies both halves for every region:

* **Sufficiency — the 546 "yes" verdicts.** A packing is built, one present at
  a time, and then re-derived from its own records: every present is an exact
  rotation or flip of its shape, inside the region, and no cell carries two
  presents. A witness cannot be faked, so these 546 are proofs.
* **Necessity — the 454 "no" verdicts.** Those regions never reach the search:
  their presents ask for more cells than the region has, and area is a hard
  bound. Proofs.
* **The two halves partition the input**: `fits + over == 1000`, `agree ==
  1000`, `unresolved == 0`. Every region is decided exactly once, by one of
  the two proof-carrying verdicts.

That is why the answer is exact *whatever* the packer's completeness — and the
packer is demonstrably not complete: on the micro-cases it misses two exact
tilings that the complete search finds (cases 8 and 9), and on the real input
it is never asked to prove anything. If the greedy had failed on an
area-feasible region, that region would land in `unresolved` and the program
would print a warning instead of quietly counting it as a "no".

## Where part 2 came from, and which anchor tier

**Advent of Code 2025 ran for twelve days, and day 12 is the finale with a
single star: there is no part 2.** The puzzle ends with a star appearing above
the tree and no second question is asked. The program prints this with its
sources rather than inventing a second puzzle.

Evidence, fetched once each and independent of each other:

* <https://aoc.winslowjosiah.com/solutions/2025/day/12/> — "It is now Day 12,
  and the final day of Advent of Code!", and reports "all 23 stars": eleven
  two-star days and one single-star day is 23, so day 12 carries one star.
* <https://baerentsen.space/aoc-2025-day-12/> — a section headed "Part 2: The
  Star on the Tree" whose whole content is that a star appears above the tree
  and "No code needed".
* The statement page itself, fetched unauthenticated, shows **one** `<h2>`
  and **one** question before the login prompt — the shape of a one-star day.

So the dispatch premise "days 13–25 have neither statement nor input" is
right about the files and wrong about the cause: **2025 has no days 13–25 at
all**. Nothing is blocked; the season ended at day 12.

**Anchor tier reached: tier 1 (external), for part 1 — and the same tier for
the absence of a part 2.**

* *Part 1, external:* `example.txt` is the statement's own worked example
  (six shapes, three regions) and the statement's own answer for it is **2**.
  `./day12 example.txt` prints **2**. Three write-ups agree on that value
  (Winslow, Baerentsen, and the AP-CSA-edition write-up, which also says
  "This worked on the sample (finding 2 feasible regions)").
* *Part 1, second external anchor:* the statement *prints a packing* for its
  4×4 region. `witness.txt` holds that diagram, and the check parses the
  letters and requires each letter's cell set to be an exact rotation or flip
  of shape 4 in **this program's own orientation table**. It passes — so the
  table really does contain the quarter turn and the mirrored quarter turn the
  statement used.
* *Part 2:* tier 1 as well — not a self-derived guess, but two independent
  published statements that the second part needs no code.

**Residual risk, stated plainly.** The real-input answer rests on my own
solver, and puzzle inputs are per-account: a different account's `day12.txt`
would have different regions and a different answer, so **546 is an answer to
*this* input and cannot be checked against anyone else's**. What *can* be
checked, and is, is the interpretation (2 on the statement's example) and the
soundness of the two halves. The one thing I could not prove by machine is the
statement's own claim about its third example region (49 presents' worth of
cells in 60 cells, and no packing exists): the complete search exhausts its
2 000 000-node budget on that 12×5 region. The program reports it as *not
fitted, not proved*, and leans on the statement for the impossibility.

## The property check (`./day12 --check`)

27 assertions, all passing, no reference file involved. Its real output is
quoted in `CHECK-OUTPUT.txt`.

**1. Hand-worked micro-cases** (`micro.txt`, the *real input's* six shapes, 14
tiny regions). Every expected value below is worked out by hand in this
section and independently confirmed by the complete search — I wrote the
table before running anything, and the search agreed with all 14.

| # | region | need | truth | why, by hand |
|---|---|---|---|---|
| 1 | `3x4: 0 2 0 0 0 0` | 12 of 12 | **fits** | Two type-1s tile a 3×4 exactly: `###/##./#..` on rows 0–2 leaves `#../##./###`, which is a rotation of the same shape. |
| 2 | `4x3: 0 2 0 0 0 0` | 12 of 12 | **fits** | The transpose of case 1; turn case 1's packing a quarter turn. |
| 3 | `3x5: 0 0 0 3 0 0` | 15 of 15 | **does not fit** | Every orientation of shape 3 (`..#/.##/##.`) has **exactly one cell in its bottom row**. The last row of the region can only be covered by presents whose bottom row *is* that row, so covering row 4 needs three presents each contributing one cell — all three therefore end at row 4, and rows 0–1 are then covered by nobody. Area says yes; geometry says no. |
| 4 | `5x3: 0 0 0 3 0 0` | 15 of 15 | **does not fit** | The transpose of case 3. |
| 5 | `4x4: 0 0 0 0 2 0` | 14 of 16 | **does not fit** | Two 3×3 boxes inside a 4×4 always share a 2×2 block. A present is its box minus its centre cell, so it covers **at least 3 of that block's 4 cells**; two such sets must intersect (3+3 > 4). Overlap. Area says yes; geometry says no. |
| 6 | `3x3: 0 0 0 0 1 0` | 7 of 9 | **fits** | The present *is* the shape; place it as drawn. |
| 7 | `3x3: 0 0 0 0 2 0` | 14 of 9 | **does not fit** | Area, by 5 cells. |
| 8 | `3x6: 1 1 0 1 0 0` | 18 of 18 | **fits** | Exact tiling; the complete search produces it and the witness verifies. |
| 9 | `3x8: 0 4 0 0 0 0` | 24 of 24 | **fits** | Four type-1s tile a 3×8 exactly; found by the complete search. |
| 10 | `2x3: 1 0 0 0 0 0` | 7 of 6 | **does not fit** | Area by one cell — and, independently, every orientation of every shape here is 3×3, so nothing fits a 2×3 region at all. |
| 11 | `1x1: 0 0 0 1 0 0` | 5 of 1 | **does not fit** | Area. |
| 12 | `3x3: 0 0 0 0 0 0` | 0 of 9 | **fits** | Zero presents; the edge case of an all-zero quantity list. |
| 13 | `4x4: 0 0 1 0 2 0` | 21 of 16 | **does not fit** | Area by 5 cells. |
| 14 | `6x6: 1 1 1 1 1 1` | 39 of 36 | **does not fit** | Area by 3 cells. |

Each case runs through **one** entry point — `decide()`, the function the
answer uses — plus the complete search, plus the area bound, plus the witness
and the two involutions; it also records the greedy's own verdict separately,
so the table above shows where the greedy is incomplete (cases 8 and 9).

**2. Independent oracles, none of them a copy of the solver's arithmetic.**

* *Necessity vs. sufficiency.* The area bound and the packer disagree by
  construction on cases 3, 4 and 5 — that is what makes them independent in
  kind. The check asserts the area bound's soundness ("area says no ⇒ nothing
  fits") on every micro-case, and asserts the two halves partition the real
  input.
* *A complete search* (`exhaustive()`) on every region small enough to finish
  (< 400 cells). Different algorithm entirely: branching on the first cell with
  a *skip* branch, versus the packer's constructive lowest-leftmost fill. It is
  the oracle that measures the packer's incompleteness.
* *The transposition involution, in two directions* — `day06`'s trick, which is
  worth stealing. `turn_check()` sends every present of a witness through a
  quarter turn into the transposed region and re-derives it from the records;
  `flip_check()` mirrors every cell in the diagonal (`xtr`, the transpose
  table, which the solver itself never uses) and re-derives that. All 546
  witnesses survive both. A quarter turn and a mirror are also involutions, so
  a *failed* turn would be caught by re-turning — but the stronger property is
  used: the turned witness is re-derived from scratch and must itself be a
  valid packing.
* *A second greedy* with the orientation list run backwards
  (`solve_alt()`): 546 again, with 0 regions it could not decide.
* *Permutations of the input*: region lines reversed, every diagram turned a
  half turn, every diagram mirrored — 546 each time. The orientation table is
  closed under rotation and mirroring, so a solver that leaned on the
  diagrams' *drawn* orientation, or summed something order-dependent, fails
  all three.
* *The statement's published witness* (`witness.txt`) against the orientation
  table — the external anchor described above.

**3. Invariants**, computed from the input rather than from the run: shape
count 6 and region count 1000 (both counted by hand outside the program);
`fits + over == 1000`; every region decided exactly once; 0 unresolved;
presents placed == presents listed (103 656 both ways); cells asked for ≤ cells
available (673 791 of 983 393, 68 %); every "yes" carries a witness that
re-derives *and* survives both involutions.

**4. Defect injection.** Twelve single-point mutations of the solver, each
applied through `--inject N`, each run against a reduced battery (the 14
micro-cases through `decide()`, the whole micro file through `solve_all()`, the
first 60 real regions, and the statement's first two example regions).
**8 caught, 4 missed**:

| # | injected defect | caught | by what |
|---|---|---|---|
| 1 | only three quarter turns in the orientation generator | yes | micro cases: `decide()` stops matching the complete search (4 assertions) |
| 2 | the mirror loop dropped (rotations only) | yes | same (4) |
| 3 | search starts one cell higher (`hint - 1` instead of `hint - 2`) | **no** | see below |
| 4 | area test `<` instead of `<=` | yes | the micro file through `solve_all()`: three exact fits flip to "over" |
| 5 | position scan restarted from 0 instead of the frontier | **no** | see below |
| 6 | the packer builds the grid transposed | yes | out-of-bounds marks, witness check (6) |
| 7 | presents placed smallest-shape-first | **no** | see below |
| 8 | the orientation table keeps duplicates | **no** | see below |
| 9 | placement bound off by one (last row/column unusable) | yes | a region the packer can no longer fill; the sandwich notices (4) |
| 10 | the witness re-derivation swaps `r0` and `c0` | yes | witness check (8) |
| 11 | trust the area bound, never pack anything | yes | `fits + over != regions`, and the micro cases where area is not enough (5) |
| 12 | the quarter-turn check uses the half-turn table | yes | `turn_check()` fails on every witness (5) |

**The four misses, and why I believe they are equivalent rather than merely
undetected.** Defects 3, 5, 7 and 8 only change the packer's *search*: which
positions it offers, or in what order it tries shapes and orientations. Each
one leaves the two halves of the sandwich intact and still verified — the
check still re-derives 546 witnesses and still rejects the same 454 regions by
area — so under this design **no search-only defect can change the answer, and
no check that looks at the answer can see one**. That is a feature of the
sandwich and also its blind spot, so it is worth stating exactly: to catch
these, the battery would have to assert something about *which* packing the
greedy finds (a golden packing), which would be a golden file, which proves
determinism and not correctness. I have left them out rather than invent a
check that only looks busy. Concretely: defect 3 makes the search strictly
*less* permissive (it can skip a valid origin), and every area-feasible region
still packs; defect 5 makes it strictly more permissive; defect 7 changes the
shape order and every region still packs; defect 8 adds duplicate orientations
to the table, which only shifts the order the greedy prefers.

## What the search has to get right (a bug worth recording)

The obvious complete-search rule — "the first free cell must be covered by the
next present" — is **only sound for an exact tiling**. With leftovers allowed it
is wrong, and the statement's own 4×4 example proves it: that region has two
spare cells, so a search using that rule reports the statement's *fitting*
region as impossible. `exhaustive()` therefore branches twice at the first
cell: put some remaining present there, **or declare the cell empty for good**.
The skip branch is what makes it complete; `remarea > freecells` prunes, so at
most `freecells - remarea` cells can be abandoned in a row.

## Files

| file | what |
|---|---|
| `day12.y` | the program: parser, orientation tables, constructive packer, witness verifier, complete search, property battery |
| `input.txt` | the vendored puzzle input (per-account personal data, **gitignored**) |
| `example.txt` | the statement's own worked example — the tier-1 anchor for part 1 |
| `witness.txt` | the packing diagram the statement prints for its 4×4 region |
| `micro.txt` | 14 hand-worked micro-cases built from the real input's shapes |
| `EXPECTED` | exact stdout of `./day12` |
| `CHECK-OUTPUT.txt` | exact stdout of `./day12 --check` |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |

`sha256`: `day12.y` `ad4b4cc77f7f63b9485ef964a5fd243a2fb2404e52bb28f174a0dbbf4a46b012`, `input.txt` `f4959b8f…`, `example.txt` `2cf2eb20…`,
`micro.txt` `1479b1d4…`, `witness.txt` `49696dc3…`.

## Compiler workarounds and findings

Nothing here needs a workaround: no `break`/`continue` (guard flags and
positive conditions instead), no `sort` (an insertion sort over six shape
indices), no `float`, no character literals (`c':'`), no fixed-point. The
arena rule is respected — the scratch arrays are module-level and grown once.

Two things about this language that cost me a trap each and are worth knowing
(they are documented behaviours, **not** bugs, and nothing is filed):

* **Array growth prepends.** `arr *= v` puts `v` at the *front*, so growing an
  indexed scratch array inside a loop shifts everything already written. The
  complete search's descent path is indexed by depth; growing it mid-search
  silently moved the records and the witness verification failed. Size it once
  before the loop, or clear and rebuild.
* **A record literal is `{ … }`**, not `TypeName { … }` — a `type` alias names
  the type for annotations, it is not a constructor.

**Filed in `examples/BUGS.md` / `examples/SUGGESTIONS.md`: nothing.** Every
failure during this build was my own code (a mis-parsed fixture, an
unsound search rule, a stale global, a transform applied in the wrong
direction), and filing it as a compiler finding would be noise.

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
