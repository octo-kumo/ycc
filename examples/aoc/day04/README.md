# AoC 2025, day 4 — "Printing Department", in Y

The printing department is a diagram of big paper rolls: `@` is a roll, `.` is
bare floor. A forklift can reach a roll when there are **fewer than four rolls
in the eight adjacent positions** — positions off the edge of the diagram are
bare floor, not rolls.

* **Part 1** — how many rolls can a forklift reach in the diagram as given?
* **Part 2** — take away *every* reachable roll **at once**, which may leave
  more rolls reachable; repeat until no roll is reachable. **How many rolls were
  taken away in total?**

The input is a **135 × 135 rectangle** of `.` and `@` (18 360 bytes, 135 lines
of 135 bytes plus the final newline). That shape was read off the file, not
assumed: `rescan()` walks the raw bytes and the check asserts the parse and the
rescan agree on width, height and roll count. The parser does not require
rectangularity — a short row is read as bare floor to its right — and it
tolerates `\r\n`, blank trailing lines and ragged rows.

## Answers (real input, `input.txt`)

| | |
|---|---|
| diagram | 135 × 135 |
| rolls | 11 848 |
| **part 1** | **1389** |
| **part 2** | **9000** |
| rolls left standing after the cascade | 2 848 |
| peel rounds | 49 (first round 1 389, last four 2, 1, 1, 2) |

`EXPECTED` is the byte-exact stdout of `./day04` (298 bytes).

## Where part 2 comes from — read this before trusting the answer

**Part 1's definition is the puzzle statement's, read from
`https://adventofcode.com/2025/day/4` (fetched once). Part 2's is not.**
Part 2 of every AoC day is login-gated, so an unauthenticated fetch of the
statement returns only part 1 — that page carries exactly one `<h2>` and one
puzzle, then a login prompt. Part 2's wording below was therefore taken from
public write-ups, **not from AoC**, and it is reproduced here in my own words
rather than quoted:

> Repeatedly take away, all at once, every roll that currently has fewer than
> four rolls around it, until nothing is reachable; count the total taken.

Sources, both fetched 2026-10-04:

* <https://www.jongerius.me/posts/2025/12/04/printing-department/> — Java; states
  the example's part-2 result explicitly.
* <https://donaldh.wtf/2025/12/2025-aoc-day-4-printing-department/> — Raku;
  asserts the same value in its test: `is day-four('4-test.txt'), 43`.
* Four further write-ups agree on the rule and on the batch/simultaneous
  semantics: <https://baerentsen.space/aoc-2025-day-4/> (Python, queue),
  <https://robit.house/blog/2025/12/aoc2025day04/> (JS), and two that call the
  simultaneity out as *the* pitfall —
  <https://joshcena.com/notes/aoc/2025/4/> and
  <https://scerruti.github.io/AoC2025/writeups/day04/>.

### The two anchors

An AoC answer is one integer, so a misread rule reproduces a wrong integer
perfectly. Both readings are anchored against published values on the
statement's own 10 × 10 example, which is vendored as `example.txt`:

| anchor | value | source | asserted by |
|---|---|---|---|
| part 1 on the example | **13** | the statement itself | `--check` |
| part 2 on the example | **43** | the two write-ups above | `--check` |

`./day04 --input example.txt` prints 13 and 43, and `--check` asserts both
through the **shipped** solve path (`solve_part1`/`solve_part2`), not through a
check-only helper. If my reading of part 2 were wrong, one of those two numbers
would move.

Confidence: **high** for part 1 (the statement's own wording, its own published
value). **Good but not certain** for part 2 — five independent write-ups,
published on four different days by five different authors, agree on the rule
*and* on the published example value 43, and two of them name simultaneity as
the trap. I could not read AoC's own part-2 text, so if the true rule differs
in some way none of the five noticed, the real-input 9000 would be wrong while
every check in this folder still passed.

As a sanity check on the *magnitude*, one write-up reports 9 518 for part 2 on
its own input; inputs are per-account, so that is a different diagram, but it is
the same order as 9 000 here.

## Build and run

```sh
cd examples/aoc/day04
../../../refs/ycc.ref day04.y -o day04     # build (three `..`, not four)
./day04                                    # both answers, from input.txt
./day04 --check                            # the property battery
./day04 --input example.txt                # the statement's 10x10 example: 13 and 43
./day04 --heap                             # heap_used() around each phase
./day04 --help
```

**Pinned compiler** — `refs/ycc.ref`, sha256

```
6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e
```

That is the only compiler used here and the only one that may be. The path is
`../../../refs/ycc.ref` — **three** `..`: `day04 → aoc → examples → compiler`.
Four levels resolves to `examples/refs/ycc.ref`, which does not exist.

**The pin moved while this folder was being built**, from
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631` to the sha
above. Everything was rebuilt and re-run under the new pin: `EXPECTED` — first
generated under the old one — still reproduces **byte for byte**, both anchors
still reproduce, and all 214 checks still pass. Nothing here was adjusted to
match: the numbers are the same because the rules are the same.

**Vendored data** — `input.txt` (the puzzle input, personal per-account data,
gitignored by the folder's own `.gitignore`) sha256
`8ee1bb2208ec30ecadca7a7eb62b006d12abdcbe950b598b1e70d57968c13b6c`;
`example.txt` (the statement's worked example, public) sha256
`8e5b2acf278c82defe846f4d7fa6cec9e3e5e438154bd98506709e648a814429`.

## What to look at

| in `day04.y` | why it is interesting |
|---|---|
| `is_open`, `nb_count` | the whole rule in two functions; `defect` selects an injected misreading |
| `part1_direct` | method A — count the eight neighbours on the spot, per roll |
| `part1_propagated`, `neighbour_counts` | method B — build every count in one outward pass, then read the answers off it |
| `part2_rounds` | method A — the statement's shape: rescan the whole diagram each round, take nothing away until the scan finishes |
| `part2_incremental` | method B — the same answer with no rescan at all; removing a roll only ever lowers a neighbour's count, so each cell's count is decremented at most 8 times over the whole run |
| `certify` | not a rerun: a **proof** of a peel from its round labels alone (see below) |
| `check_order_independence` | the one finding worth reading the code for — why the total cannot see a real defect |
| `micro_cases` | the nine hand-worked micro-diagrams (A–I below); J is `EXAMPLE_ROWS` |
| `check_exhaustive` | 69 630 diagrams, every one of them, at two sizes |
| `check_defects`, `run_defective` | twelve injected defects, each of which must be caught |

## The rule, as implemented

A roll at `(y, x)` is reachable when the number of `@` in its eight neighbours
is `< 4`. `DY`/`DX` are the eight offsets — up, down, left, right, then the four
diagonals, orthogonal first. Out-of-bounds is bare floor.

Part 2 removes a whole round's worth **simultaneously**: a roll removed in
round *t* is still counted as a roll by every other roll's test *within* round
*t*, and stops counting from round *t+1*. This is the subtlety four of the
write-ups single out, and `part2_rounds` implements it by collecting the round
into `acc` and only then clearing it.

## The property check (`./day04 --check`)

`EXPECTED` proves determinism, never rightness. This check has **no reference
file in it**: every expectation is either worked out by hand below, published by
the statement, published by a cited write-up, or derived by a second method.

### 1. Hand-computed micro-cases — the arithmetic, so you can check it

All ten run through the real parser and all four counters. The counts below are
neighbour counts; "reachable" means fewer than four.

| | diagram | rolls | part 1 | rounds (rolls taken per round) | part 2 | left |
|---|---|---|---|---|---|---|
| A | `@` | 1 | 1 | 1 | 1 | 0 |
| B | `@@`/`@@` | 4 | 4 | 4 | 4 | 0 |
| C | 3 × 3 block | 9 | 4 | 4 4 1 | 9 | 0 |
| D | 4 × 4 block | 16 | 4 | 4 | 4 | 12 |
| E | plus, 5 × 5 | 9 | 4 | 4 4 1 | 9 | 0 |
| F | one row of 5 | 5 | 5 | 5 | 5 | 0 |
| G | 2 × 5 block | 10 | 4 | 4 4 2 | 10 | 0 |
| H | 5 × 5 ring | 16 | 16 | 16 | 16 | 0 |
| I | `.@@.`/`@@@@`/`@@@@`/`.@@.` | 12 | **0** | — | **0** | 12 |
| J | the statement's 10 × 10 | 71 | **13** | 13 12 7 5 2 1 1 1 1 | **43** | 28 |

Worked out:

* **A** — one roll, no neighbours. 0 < 4, so 1, and it is the whole cascade.
* **B** — each of the four has exactly 3 neighbours. All four come away in one
  round.
* **C** — the four corners have 3 and go; the four edge centres have 5 and stay.
  With the corners gone each edge centre has 3 → the four edges go. What is left
  is the centre, whose eight neighbours were all on that second round's list, so
  it has **4**, not 3, and stays a third round. Only then, alone, it goes. That
  is the case that catches "three rounds of four, four, four".
* **D** — same at 4 × 4, and then the peel **stops**: after the four corners go,
  each of the twelve survivors has exactly 4 survivors around it (e.g. `(0,1)`
  has `(0,2) (1,0) (1,1) (1,2)`), so nothing else is reachable. 12 roll left:
  the survivors are a 4-core, and `part 2 < rolls` happens.
* **E** — four tips with 1 neighbour go. The four arms and the centre then have
  **exactly 4** each and must *not* be taken: this is the case the statement's
  "fewer than four" turns on, and taking them would make `D_LE` (below) agree
  with the truth here. Next round the four arms have 3 and go, and then the
  centre.
* **F** — a single row: the ends have 1 neighbour, the middle three have 2. All
  five go at once. Also the diagram's **edge**: off-diagram positions are not
  rolls.
* **G** — the four corners have 3; the six others have 5. Round 2 takes
  `(0,1) (0,3) (1,1) (1,3)` (3 each) and leaves `(0,2)` and `(1,2)`, which by
  then have 1 neighbour each.
* **H** — the roll at the top middle has 2 neighbours, the one below-left of it
  has 3, and no roll in the ring has 4: the whole ring is reachable in one round,
  so `part 1 = part 2 = rolls`.
* **I** — **nothing is reachable**, and that is the case to look at. Each of the
  12 rolls has either 4 or 7 neighbours: the six "corner" rolls
  `(0,1) (0,2) (1,0) (1,3) (3,1) (3,2)` each have exactly 4, and the six "inner"
  ones `(1,1) (1,2) (2,1) (2,2)` and the two edge rolls `(2,0) (2,3)` each have
  exactly 7. So **part 1 = part 2 = 0** is a real answer, and a grid can produce
  it. That matters: a check which compared `part 1 == 0` with `part 2 == 0`
  would pass here without proving anything, which is why every assertion about
  the real input states a non-zero guard first, and why `D_GE` (which inverts the
  rule and so returns 0 for the *example*) is caught by this case.
* **J** — the statement's example; 13 and 43 are the two anchors above.

### 2. Two methods per part, plus a proof

| quantity | method A | method B | how they can differ |
|---|---|---|---|
| part 1 | `part1_direct`: count the 8 neighbours of each roll on the spot | `part1_propagated`: one outward pass builds every cell's count, then read off | different accumulation order; a bounds bug shows up in one and not the other |
| part 2 | `part2_rounds`: rescan the whole diagram every round | `part2_incremental`: maintain the counts, never rescan | brute force vs O(rolls · 8) |
| part 2, again | `certify`: proves the round labels, never re-peels | — | see below |

Part 2's two methods are compared on the **whole round vector**, not just the
total: `part 2 == part 2` on a single integer would survive an off-by-one in
which round a roll came off in.

`certify` is the strongest of the three, and it is a proof rather than a
corroboration. It never peels. It takes the round labels and walks *backwards*:

* **every removal was legal** — for each roll taken in round *t*, the rolls still
  standing when round *t* opened are the survivors plus everything taken in
  rounds *t*, *t+1*, …; each such roll must have had `< 4` neighbours among them.
  This shows no more rolls than this many could ever come away.
* **the peel had finished** — every survivor must have `>= 4` neighbours among
  the survivors, or another round was available. This shows no fewer could.

Together they pin the answer exactly. `checked` must equal the number of rolls
taken, so a peel the certificate has not fully accounted for cannot pass.

### 3. Exhaustive, not sampled

Every non-empty diagram of a given size, both bits free:

| sweep | diagrams | what runs |
|---|---|---|
| 4 × 3 | **4 095** = 2¹² − 1 | both part-1 methods, both part-2 methods, the invariants, **and the certificate** |
| 4 × 4 | **65 535** = 2¹⁶ − 1 | both part-1 methods, both part-2 methods, the invariants |

69 630 diagrams, zero disagreements, zero invariant violations, zero unproved
peels. The expected counts `4095` and `65535` are **literals in the call**, not
computed by the same expression that drives the loop — a sweep that covered the
wrong number of diagrams cannot pass. (It did, once: the loop that was supposed
to produce 2ⁿ was computing the next power of two *above* n, so it covered 15
diagrams and reported a pass. The hand-written expectation is what caught it.)

The **certificate is not vacuous** at either size: 4 × 3 is the smallest size at
which the peel stops early often enough to matter, and the sweep asserts the
spread — 8 distinct part-1 and 12 distinct part-2 totals at 4 × 3, 13 and 16 at
4 × 4, a diagram with exactly one reachable roll, a diagram where every roll
comes away, and (at 4 × 4) diagrams where rolls survive. No 4 × 3 diagram can
have a survivor — the smallest that can is 4 × 4 — so demanding one there would
be a check failing for the wrong reason; the flag that says so is named
`want_survivors`.

### 4. Invariants

Checked on every one of the 69 630 diagrams, on the example, and on the real
input: `0 <= part 1 <= part 2 <= rolls`; the round counts **sum** to part 2;
`part 2 == rolls - left`; no round is empty and no round list is longer than the
rolls; `checked == part 2` and `surv == left` from the certificate.

### 5. An independent second reader, and presence guards

`rescan()` walks the raw bytes and counts rows, widths and rolls without going
through `fs.read_lines()` or `parse_rows()`; the two must agree, so two
unrelated readers saw the same file. Before anything is compared, the values are
shown **present**: the file is readable, every row is `.`/`@` only, the
dimensions are sane, the roll count is non-zero, and the rescan's numbers are
non-zero. Part 1 and part 2 must each be non-zero on the real input (they are
1 389 and 9 000) — micro-case I above is exactly why "non-zero" cannot simply be
assumed of a part-1 answer in general.

### 6. Order independence — the finding worth reading

Removing a roll **during** the scan instead of after it is the classic misreading
of this puzzle, and `D_ASYNC` injects it. It produces the **same total** on all
ten micro-cases, on the statement's example, and on all 4 095 4 × 3 diagrams.
That is not luck: both procedures stop exactly at the 4-core — the largest set
of rolls in which every roll has four or more neighbours — so the *set* of rolls
that comes away, and therefore the total, is the same whatever order they come
away in. Only the round boundaries move, and visibly:

```
round vector, synchronous:  13 12 7 5 2 1 1 1 1
round vector, scan order:   30 9 4
```

So a check that compared only the two answers would be **blind** to a real
misreading of the statement. `check_order_independence` asserts both halves —
same total over all 4 095 diagrams, different round vectors on 2 026 of them —
and `run_defective` compares round vectors so `D_ASYNC` is caught. This is the
single most useful thing `--check` does, and it is a property, not a defect.

### 7. Defect injection — twelve, all caught

Each defect is a genuinely different implementation, reachable only from
`check_defects()`. A defect is **caught** if it disagrees with the truth on any
of the ten micro-cases or the example (comparing part 1, part 2, `left` *and*
the round vector) **or** if the certificate rejects it. Real output:

```
     caught D_LE four-or-fewer: wrong answer on 5 of 10 grids (first: C 3x3 block), certificate rejects 0
     caught D_GE inverted: wrong answer on 10 of 10 grids (first: A single roll), certificate rejects 10
     caught D_SELF counts itself: wrong answer on 7 of 10 grids (first: B 2x2 block), certificate rejects 6
     caught D_FOUR no diagonals: wrong answer on 6 of 10 grids (first: C 3x3 block), certificate rejects 1
     caught D_EDGE off-grid counts: wrong answer on 9 of 10 grids (first: A single roll), certificate rejects 9
     caught D_WRAP wraps: wrong answer on 8 of 10 grids (first: A single roll), certificate rejects 8
     caught D_LOOP last column unread: wrong answer on 9 of 10 grids (first: A single roll), certificate rejects 9
     caught D_ASYNC removes in the scan: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 9
     caught D_ONCE first round only: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 4
     caught D_LAST last round only: wrong answer on 10 of 10 grids (first: A single roll), certificate rejects 9
     caught D_NOOP removes nothing: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 4
     caught D_LABEL mislabels the rounds: wrong answer on 0 of 10 grids (first: ), certificate rejects 3
ok   every injected defect is caught   11/12 wrong answers, 11/12 certificate rejections
```

**12 of 12 caught**; the union is 12, so every defect is caught by at least one
mechanism. Two are worth reading:

* **`D_LE`** ("four or fewer") is the misreading of "fewer than four", and the
  certificate **cannot** see it — 0 rejections — because every roll it takes
  away really is reachable. Only the hand arithmetic catches it, and it takes
  micro-cases C and E, where rolls with exactly four neighbours must be left.
  A defect the certificate is blind to is precisely why the micro-cases exist.
* **`D_LABEL`** (right total, rounds mislabelled) is the mirror image: 0 wrong
  answers, and only the certificate rejects it. So each mechanism covers a class
  the other cannot see.

### 8. What the check caught in *this* implementation

Three real bugs, all found by the battery rather than by reading the code:

1. **`DY`/`DX` had the centre in them and `right` missing.** `DY =
   [-1, 0, 1, 0, …]`, `DX = [0, 0, 0, -1, …]` — offset 1 was `(0, 0)`, the
   roll itself. Undercounting by one gave 742 instead of 1 389, and 9 instead of
   13 on the example. The example anchor caught it immediately, which is the
   whole reason to have anchors.
2. **The sweep's `2ⁿ` loop computed the next power of two *above* n**, so it
   covered 15 diagrams and reported "0 disagreements". Caught by the
   hand-written `4095`/`65535`.
3. **The sweep skipped its last diagram** (`while (mask < cases)` excluded
   `mask == 2ⁿ − 1`), so the all-`@` 4 × 4 — the one with the largest survivor
   set — was never tested. Caught by comparing the survivor count against an
   independent Python sweep of the same 65 535 diagrams.

## Confirmation from outside this folder

The answers were re-derived by a throwaway Python script written independently
of `day04.y`, with four different algorithms over four different data
structures. All four agree with the program, and with each other:

| | algorithm | part 1 | part 2 |
|---|---|---|---|
| A | a `set` of `(x, y)` pairs, counted on the spot | 1389 | — |
| B | a padded `[[str]]`, counted with explicit bounds checks | 1389 | — |
| C | synchronous rounds, one full rescan per round | 1389 | 9000 |
| D | a BFS queue, removing one roll at a time | — | 9000 |
| E | a k-core by degree buckets, no rounds at all | — | 9000 |

plus 2848 survivors with minimum survivor degree **4**, and 49 rounds whose
first six (1389, 1085, 898, 721, 612, 531) and last four (2, 1, 1, 2) are the
numbers `EXPECTED` prints. C, D and E are the same three shapes as the Y
program's own methods, so this is a cross-implementation check rather than a
cross-algorithm one — but D and E in particular share no code with each other or
with the Y source, and the 4 × 4 survivor count (16) is what caught the sweep
off-by-one above.

Writing that script was itself instructive: **two of its four peels were wrong
on the first run** — a BFS that dropped the roll from the set *after* testing its
neighbours (so the leaving roll was still counted), and a k-core that decremented
a neighbour twice for a duplicated work entry (so it peeled 11 293 instead of
9000). Both produced plausible integers. They were caught by comparing the
algorithms against each other and against the invariants — which is the argument
for doing this at all.

## The check's actual output

```
  micro A single roll: 1x1 rolls=1 part1=1/1 part2=1/1 left=0/0 rounds=[1] cert bad=0 checked=1 surv=0
  micro B 2x2 block: 2x2 rolls=4 part1=4/4 part2=4/4 left=0/0 rounds=[4] cert bad=0 checked=4 surv=0
  micro C 3x3 block: 3x3 rolls=9 part1=4/4 part2=9/9 left=0/0 rounds=[4 4 1] cert bad=0 checked=9 surv=0
  micro D 4x4 block: 4x4 rolls=16 part1=4/4 part2=4/4 left=12/12 rounds=[4] cert bad=0 checked=4 surv=12
  micro E plus 5x5: 5x5 rolls=9 part1=4/4 part2=9/9 left=0/0 rounds=[4 4 1] cert bad=0 checked=9 surv=0
  micro F 1x5 row: 5x1 rolls=5 part1=5/5 part2=5/5 left=0/0 rounds=[5] cert bad=0 checked=5 surv=0
  micro G 2x5 block: 5x2 rolls=10 part1=4/4 part2=10/10 left=0/0 rounds=[4 4 2] cert bad=0 checked=10 surv=0
  micro H ring 5x5: 5x5 rolls=16 part1=16/16 part2=16/16 left=0/0 rounds=[16] cert bad=0 checked=16 surv=0
  micro I nothing reachable: 4x4 rolls=12 part1=0/0 part2=0/0 left=12/12 rounds=[] cert bad=0 checked=0 surv=12
ok   example [part 1 = 13, from the statement]   part 1 = 13
ok   example [part 2 = 43, from the public write-ups]   part 2 = 43
  example: 10x10 rolls=71 part1=13/13 part2=43/43 left=28/28 rounds=[13 12 7 5 2 1 1 1 1] cert bad=0 checked=43 surv=28
ok   exhaustive 4x3: sweep is complete   4095 diagrams, expected 4095
ok   exhaustive 4x3: methods agree   4095 non-empty diagrams, 0 disagreements
ok   exhaustive 4x3: invariants hold   4095 non-empty diagrams, 0 violations
ok   exhaustive 4x3: certificate proves every peel   4095 non-empty diagrams, 0 unproved
ok   exhaustive 4x3: sweep is not vacuous   8 distinct part 1, 12 distinct part 2, 4095 with part 1 > 0, 12 with part 1 == 1, 4095 fully peeled, 0 with survivors, of 4095
ok   exhaustive 4x4: sweep is complete   65535 diagrams, expected 65535
ok   exhaustive 4x4: methods agree   65535 non-empty diagrams, 0 disagreements
ok   exhaustive 4x4: invariants hold   65535 non-empty diagrams, 0 violations
ok   exhaustive 4x4: sweep is not vacuous   13 distinct part 1, 16 distinct part 2, 65534 with part 1 > 0, 20 with part 1 == 1, 65519 fully peeled, 16 with survivors, of 65535
ok   order independence: same total, different rounds   rounds [30 9 4] = 43, scan order [13 12 7 5 2 1 1 1 1] = 43
ok   order independence: same total over all 4x3 diagrams   4095 diagrams, 0 disagreements
ok   order independence: round vectors really do differ   2026 of 4095 diagrams split into different rounds
ok   input.txt present   135 lines, 18360 bytes
ok   input well formed   135 lines, all '.' and '@'
ok   input shape sane   135 x 135
ok   rolls present   11848 rolls
ok   rescan present   135x135 rolls=11848
ok   parse == rescan   135x135/11848 vs 135x135/11848
ok   anchor part 1 == 13 (statement)   13
ok   anchor part 2 == 43 (write-ups)   43
ok   part 1 present   1389
ok   part 2 present   9000
ok   part 2 >= part 1   9000 >= 1389
ok   part 2 == rolls - left   9000 == 11848 - 2848
real input: 135x135, 11848 rolls, part 1 = 1389, part 2 = 9000, 2848 left after 49 rounds
     caught D_LE four-or-fewer: wrong answer on 5 of 10 grids (first: C 3x3 block), certificate rejects 0
     caught D_GE inverted: wrong answer on 10 of 10 grids (first: A single roll), certificate rejects 10
     caught D_SELF counts itself: wrong answer on 7 of 10 grids (first: B 2x2 block), certificate rejects 6
     caught D_FOUR no diagonals: wrong answer on 6 of 10 grids (first: C 3x3 block), certificate rejects 1
     caught D_EDGE off-grid counts: wrong answer on 9 of 10 grids (first: A single roll), certificate rejects 9
     caught D_WRAP wraps: wrong answer on 8 of 10 grids (first: A single roll), certificate rejects 8
     caught D_LOOP last column unread: wrong answer on 9 of 10 grids (first: A single roll), certificate rejects 9
     caught D_ASYNC removes in the scan: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 9
     caught D_ONCE first round only: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 4
     caught D_LAST last round only: wrong answer on 10 of 10 grids (first: A single roll), certificate rejects 9
     caught D_NOOP removes nothing: wrong answer on 4 of 10 grids (first: C 3x3 block), certificate rejects 4
     caught D_LABEL mislabels the rounds: wrong answer on 0 of 10 grids (first: ), certificate rejects 3
ok   every injected defect is caught   11/12 wrong answers, 11/12 certificate rejections

property check: 214 checks, all passed
```

`--check` exits 0 on success and 1 if anything fails, so it is a real gate, not
a printout.

## Runtime and allocation (measured)

| | wall clock | max RSS |
|---|---|---|
| `./day04` (135 × 135) | **0.01–0.02 s** over 8 runs | 4 112 KB |
| `./day04 --check` (all 69 630 diagrams + 12 defects) | **0.39–0.43 s** over 5 runs | 188 432 KB |

The 135 × 135 diagram is only 18 225 cells, so the solve is bounded by the parse
and one rescan sweep per round rather than by anything interesting; the
`--check` figure is the 69 630-diagram exhaustive sweep and is the only number
here worth a second look.

`./day04 --heap` samples `heap_used()` around each phase, so the allocation
claim is measured rather than eyeballed. Real output on the 135 × 135 input:

```
heap after start:                 448
heap after read_lines:            161592  (+161144)
heap after parse:                 686024  (+524432)
heap after part 1:                686024  (+0)
heap after part 2 (rescan):       2260248  (+1574224)
heap after part 2 (incremental):  3834520  (+1574272)
```

and on the 10 × 10 example, where `part 2` costs +6 528 rather than +1 574 224:

```
heap after parse:                 69600  (+2128)
heap after part 1:                69600  (+0)
heap after part 2 (rescan):       76128  (+6528)
heap after part 2 (incremental):  82704  (+6576)
```

What that shows, and it is the point of the `-S` audit in `ORCHESTRATOR.md` §3 as well:

* **Part 1 allocates nothing at all** (+0 at both sizes). The per-cell and
  per-neighbour loops contain no allocation call — 18 225 cells and 145 800
  neighbour tests cost 0 bytes.
* **Part 2 allocates three work arrays per solve and nothing per cell.** On
  18 225 cells the cost is 1 574 224 bytes = 196 778 longs; three arrays grown
  by doubling from 0 to 18 225 elements allocate 8 + 16 + … + 32 768 = 65 528
  longs each, i.e. 196 584 longs, and the remaining 194 are the round vector,
  which grows by one element per round (49 rounds). So the only allocation inside
  a loop is **one amortised append per round**, and the inner loops are clean.
* No function in the solve path has a value-used `str` append (`y_str_cat`) in a
  loop; the `-S` audit finds `y_str_cat` only in the reporting functions, where
  it is outside any loop.
* `rescan`, `bad_row` and `part1_*` contain **zero** allocation calls; the 5 in
  `parse_rows` and the 16 in `part2_rounds` are the array builds at entry plus
  the per-round append described above.

## Toolkit

**Nothing is vendored.** This example needs no `fx` (no floats — every count is
an integer), no `term` (no terminal), no `fb` (no framebuffer), no `args` (two
flags are read from `argv()` directly) and no `time`. The frozen toolkit in
`examples/_toolkit/` is byte-identical and untouched; its shas, if you want them
for a later day, are
`fx.y 4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058`,
`term.y 07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee`,
`fb.y 95a7663b7f1c7a90ff3756b51e51644ea952c9b671eeca1012b8f64e18589697`,
`args.y cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28`,
`time.y 6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b`.

**No `sort` was needed** and none is used: the roll order never matters, only
counts. There is no sorting anywhere in this folder.

## Compiler workarounds

No compiler bug was found. The facts below are language rules, worked around in
`day04.y` and visible there rather than silent:

* **`[0; n]` takes an integer literal only**, so a work array of `w * h` cells
  cannot be written in one step. Already filed as
  `SUGGESTIONS.md` §8, *a runtime-sized array*. The workaround here is to append
  zeros, which is cheaper than the alternative in that entry (allocating the
  largest buffer the input could ever need) but costs about 2n longs of arena
  growth instead of n — measured above: 524 224 bytes to hold 18 225 cells. It
  is `parse_rows`, `part2_rounds`, `part2_incremental`, `neighbour_counts` and
  `certify` that pay it.
* **A `def` is a first-class value**, so the injected defects needed no closures:
  `defect` is a plain `long` parameter. No closure is created anywhere in this
  folder (the C twin has no function value to store one in).
* **`main()`'s return value is not the exit status** (`SUGGESTIONS.md` §15), so
  every error path goes through `def main() -> long { … }; exit(main())`. The
  error paths were each run: unreadable file, a directory, a file with a
  non-`.`/`@` byte, a file with no rows, a file with no rolls, an unknown flag,
  `--input` with no argument, two input files. All print a message to **stderr**
  and exit **1**; none traps. (`runtime error:` goes to stdout, which would
  silently corrupt `EXPECTED` instead of failing.)
* **There is no `break`/`continue`.** Early exit is the `done` flag in
  `part2_rounds`; "continue" is a positive `if` around the body, as in the
  neighbourhood loops.
* **`arr += v` in a loop is the append**, and the neighbour offsets `DY`/`DX`
  live at module level because a literal inside a loop body would allocate on
  every iteration (`SUGGESTIONS.md` §7). The `[long]` work arrays are built once
  per solve, not per cell or per round.
* **`>>` is arithmetic and `>>>` is logical**, so the sweep uses `>>` on a
  non-negative mask. `>>>` is never used in this folder.
* **`import fs;` resolves `src/y/std/` relative to the compiler binary**
  (`std_resolve` in `native.y` tries `<self_dir>/../src/y/std/fs.y`), so the
  build needs the toolchain's std sources beside `refs/ycc.ref` — it needs
  nothing from any sibling example folder. Verified: with only this folder, the
  compiler and `src/y/std/` present, and every other `aoc/day*` folder deleted,
  `../../../refs/ycc.ref day04.y -o day04` builds a **byte-identical** binary,
  reproduces `EXPECTED`, and passes all 214 checks.
* **No `float`, no cast syntax, no math functions**, so there was no fixed-point
  arithmetic to get wrong and `fx.y` was not needed.

## Data provenance

`input.txt` is the AoC puzzle input for this account: personal, per-account data.
It is copied in here so this folder builds and passes alone, and the folder's
own `.gitignore` keeps it out of git (the repo's `!examples/**/*.*` rule would
otherwise re-include it). No session cookie is in any file here. `example.txt`
is the statement's published worked example and is public.
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
