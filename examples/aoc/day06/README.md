# AoC 2025 day 6 — Trash Compactor, in Y

Both parts of Advent of Code 2025 day 6, solved in Y and built with the
pinned reference compiler.

```
cd examples/aoc/day06
../../../refs/ycc.ref day06.y -o day06     # build (three .., not four)
./day06                                    # both answers, from input.txt
./day06 --check                            # the property battery
./day06 --bench                            # answers + elapsed us + heap bytes
./day06 --help
```

`gate.conf` records the same two lines (`build=`, `run=`), plus `check=` for
the property battery and `gold=EXPECTED`.

**Pinned compiler.** Built and checked against `refs/ycc.ref`, sha256

```
6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e
```

The pin moves on every rebless. If `python3 ../../gate.py aoc/day06` reports
that the README's sha no longer matches, rebuild, re-run, record the new one —
never edit `EXPECTED` to fit.

## The two answers

| | |
|---|---|
| **part 1** | `7229350537438` |
| **part 2** | `11479269003550` |

`./day06 --bench` on the real input: **403–686 µs** (five runs) for the parse
and both readings of 5 rows × 3752 columns, and **410 440 bytes** of arena
allocated in total by the parse and both readings. The heap is an arena —
nothing is ever freed — so that byte count *is* the whole cost of the run.

## The puzzle, in my own words

A math worksheet has been unrolled into one very long horizontal line.
The numbers are not written in reading order; each problem is a **block of
columns**, with its numbers stacked above each other and the operator that
joins them sitting at the **bottom** of the block. Neighbouring problems are
separated by a **full column of nothing but spaces**. Inside a block the
alignment is arbitrary — the statement says the left/right alignment of the
numbers can be ignored, and in practice the rows are ragged and the operator
row is *shorter* than the number rows.

- **Part 1 asks:** add up the answers to all the individual problems. Each
  problem's numbers are read the ordinary way — one number per row, top to
  bottom — combined with that problem's operator.
- **Part 2 asks:** the same grand total, but read the way the cephalopods
  read. Each number is read **down a column** rather than across a row: the
  digits of one column, top to bottom, form one number, and the block's
  columns are taken **right to left**.

The worked example in the statement is four problems wide:

```
123 328  51 64
 45 64  387 23
  6 98  215 314
*   +   *   +
```

Its part 1 total, which the statement itself prints, is **4277556**.

### Part 2 came from write-ups, not from AoC — and how confident to be

An unauthenticated `https://adventofcode.com/2025/day/6` returns **only part
1**: one puzzle, then a login prompt (fetched once, on 2026-10-04). So
**part 2's definition is not in the statement**, and this program's part-2
reading comes from public write-ups. Three independent ones agree, and they
agree with each other on the rule:

| source | what it says part 2 is |
|---|---|
| <https://gitsith.com/aoc/2025/06> | "read *right-to-left, top-to-bottom*"; its worked sub-problem gives the numbers `434, 621, 3` |
| <https://todd.ginsberg.com/post/advent-of-code/2025/day6/> | one `Long` per column, the column's characters joined top to bottom, an all-blank column ends a group |
| <https://scerruti.github.io/AoC2025/writeups/day06/> | "spaces within columns are significant", "reading happens right-to-left within the column boundaries", "each digit position builds a separate number" |
| <https://aoc.just2good.co.uk/2025/6.html> | transposes the block; **spells out the statement example's first block as `356, 24, 1`** |

**Anchor tier reached: tier 1 (external), for both parts — but read the
detail, because the two parts are anchored differently.**

- **Part 1 is tier 1 in the strongest sense**: the statement publishes the
  example's four per-problem answers (33210, 490, 4243455, 401) *and* the
  total 4277556. `--check` asserts all five. This validates the
  interpretation **and** the implementation.
- **Part 2 is tier 1 for one block and tier 2 for the example's total.**
  Dazbo's write-up publishes the part-2 numbers of the statement example's
  **first** block as `356, 24, 1`; `day06 --check` asserts that exact string,
  and its product, 8544. That is an externally published number validating
  the *interpretation* of part 2 — which is what a tier-1 anchor is for. The
  example's part-2 **total** (3263827) is my own arithmetic, worked out in
  "the hand-computed micro-cases" below and **not** found published anywhere
  (I searched for it). As a second external pin, gitsith's published numbers
  for the example's **fourth** block sum to 1058, and this program computes
  1058 for that block too — from a *different* column alignment than his
  (his `434, 621, 3`, mine `4, 431, 623`; a coincidence, but an independent
  one). So: the rule is externally triply sourced and externally pinned on
  two of the four blocks; the example's part-2 total is self-derived and is
  **not** externally confirmed.

**The real-input answers come from this solver alone.** The anchors validate
the *interpretation*; nothing validates the real input except the property
battery below.

One consequence worth stating plainly: with one operator per problem,
multiplication binds tighter than addition is **unobservable on this input** —
each problem is either all-add or all-multiply, so "with precedence" and
"left to right, ignoring precedence" give the same number. Part 1 implements
precedence anyway (it is what the statement describes), and part 2 is a
genuinely different reading of the same bytes: the two totals differ by
4249918466112.

## What the real input actually looks like

The five lines are **not** all the same shape, and the assumption that they
would be is the first thing that would have broken a parser written from the
statement's example alone. Measured:

```
     lines                      5, all exactly 3752 columns
     line 5                     operators only ('+' or '*'), 1000 of them
     lines 1-4                  digits only, 4 operand rows
     problems                   1000, one per operator character
     separator columns          999, every one of them exactly ONE column wide
     operands per problem       4 -- one number per operand row, no problem
                                 has more than one number in a row
     block widths               409 blocks of 2 columns, 429 of 3, 162 of 4
     operators                  466 '+', 534 '*'
     digit characters           9535 in the four operand rows
     part-1 numbers             4000     part-2 numbers  2753
```

So each problem is a 2-to-4-column block holding four right-aligned numbers of
1–4 digits — **narrower blocks than the statement's example**, and every
column of a block carries a digit, which is why "a block is a run of columns
not blank in *every* row" and "the operator row's characters split the sheet
into groups" are the same thing here. The parser does not rely on that: it
finds separators as columns blank in every row (operator row included), which
is the statement's own definition, and it tolerates ragged rows, several
numbers per row, a single-operand problem, leading and trailing margin, and
a problem block narrower than its own widest number.

The widest part-2 problem is #1: `+`, four columns read as
`4157 3884 3942 634`, summing to 12617 (4157+3884 = 8041, +3942 = 11983,
+634 = 12617). `--check` prints it on every run.

## The property check

`./day06 --check` runs **63 assertions** and prints every one of them, pass or
fail. No reference file is involved: each expectation is worked out by hand
below, published by the statement, published by a named write-up, or counted
outside this program from `input.txt`. **Actual output: 63 checks, all
passed, exit status 0.**

Everything goes through `parse()` and the `total_*` functions — the same
entry points `./day06` uses, on the same input format — so a defect injected
into the real solver is really injected, rather than being re-implemented and
therefore agreeing with itself. That is `day02`'s lesson and it is why there
is no "reference implementation" of the rule anywhere in this folder.

### The hand-computed micro-cases

Four worksheets I built myself, each worked out here so a reader can check the
arithmetic without running anything. `.` marks a space.

**m1** — one digit per cell, one operator per problem:

```
4.9
2.3
+.+
```

| block | part 1 | part 2 |
|---|---|---|
| col 0, `+` | `4+2` = 6 | column 0 reads `4`,`2` → **42** |
| col 2, `+` | `9+3` = 12 | column 2 reads `9`,`3` → **93** |
| **total** | **18** | **135** |

**m2** — two leading margin columns, ragged rows (row 1 is two columns short
at one end and contributes *nothing at all* to the last problem), a block
whose leftmost column holds a digit in one row only, and a one-operand
problem:

```
..12..7.4
...3..5..
..+...+.*
```

| block | part 1 | part 2 |
|---|---|---|
| cols 2–3, `+` | `12+3` = 15 | col 3 reads `2`,`3` → 23; col 2 reads `1` → 1; **24** |
| cols 6–7, `+` | `7+5` = 12 | one column: `7`,`5` → **75** |
| col 8, `*` | `4` (one operand) | **4** |
| **total** | **31** | **103** |

**m3** — a `*` problem whose answer is 0, and a column of two zeros (two
digits long, value 0):

```
10.2
.0.3
*..+
```

| block | part 1 | part 2 |
|---|---|---|
| cols 0–1, `*` | `10*0` = 0 | col 1 reads `0`,`0` → **0**; col 0 reads `1` → 1; product **0** |
| col 3, `+` | `2+3` = 5 | one column: `2`,`3` → **23** |
| **total** | **5** | **23** |

The `00` column is also the reason `clens` exists: its value is 0 but it is
**two digits**, and `--check` asserts the digit count is 2.

**m4** — the shape the real input's widest problems have: a four-column block
with all four operand rows contributing, beside a one-column block.

```
..91..7
.238..5
4756..1
*.....+
```

| block | part 1 | part 2 |
|---|---|---|
| cols 0–3, `*` | `91*238*4756`: 91·238 = 21658, 21658·4756 = 103005448 | 186·935·27·4: 186·935 = 173910, ·27 = 4695570, ·4 = **18782280** |
| col 6, `+` | `7+5+1` = 13 | one column: `7`,`5`,`1` → **751** |
| **total** | **103005461** | **18783031** |

**And the statement's own example**, worked out the same way, which is where
the part-2 total comes from (it is not published anywhere):

| block | part 1 | part 2 (right to left) |
|---|---|---|
| cols 0–2, `*` | `123*45*6` = 33210 | **356**·**24**·**1** = 8544 |
| cols 4–6, `+` | `328+64+98` = 490 | **8**+**248**+**369** = 625 |
| cols 8–10, `*` | `51*387*215` = 4243455 | **175**·**581**·**32** = 3253600 |
| cols 12–14, `+` | `64+23+314` = 401 | **4**+**431**+**623** = 1058 |
| **total** | **4277556** (the statement says 4277556) | **3263827** |

The statement's example is also where the trailing-space business shows up:
row 0's `64` ends one column short of row 2's `314`, so the last block's
columns hold `4`, `4`,`3`,`1` and `6`,`2`,`3` — not the `434`, `621`, `3` that
gitsith's rendering of the same block produces. Both come to 1058. The
fixture is embedded in `day06.y` byte for byte, trailing spaces included.

### The independent cross-checks

**Transposition is an involution.** Presenting a block's digit grid with its
rows and columns swapped must turn part 2 into part 1 and part 1 into part 2.
`--check` feeds two *different* worksheets through the same entry point and
asserts both directions:

```
123        ->  part 1 = 33210   part 2 = 8544
 45             (3x3 grid)
  6
*
1          ->  part 1 = 8544    part 2 = 33210
24              (the same grid, transposed)
356
*
```

8544 = 356·24·1 = 1·24·356, and 33210 = 123·45·6 = 6·45·123. Nothing here
recomputes the rule; it just turns the matrix on its side.

**Three methods per part, over the same parsed sheet.** Different traversal
directions and a different evaluator shape, so a slip in one cannot be
present in all three:

| | method A | method B | method C |
|---|---|---|---|
| part 1 | forward run-splitting (multiplication binds tighter) | reverse run-splitting | identity fold (`0` for `+`, `1` for `*`) |
| part 2 | fold right to left (the cephalopods' order) | fold left to right | part 1's run-splitting evaluator, over the column numbers |

All six totals agree on both the example and the real input. Part 1's
reverse pass is what would catch a forward-accumulation slip; part 2's
left-to-right pass is what would catch an off-by-one in the right-to-left one.

**Six facts counted outside the program.** Rows, width, problem count,
operator count, the `+`/`*` split, digit characters, operand runs and column
numbers were counted from `input.txt` by hand and by an independent throwaway
script, and are asserted as literals: `5`, `3752`, `1000`, `1000`, `466`/`534`,
`9535`, `4000`, `2753`. If the parser dropped a digit or merged two blocks,
these would move.

**Invariants.**

- A problem per operator character: `nprob == nops` (the operator row is the
  one place the problem count can be counted without the block scan).
- One operand per run of digits: `sum(counts) == nruns`, where `nruns` is
  counted by the row scan and the sum by the block walk.
- **The digit budget, counted three ways**: `sum(lens) == sum(clens) == ndig`
  — the same 9535 digits seen once as row-runs and once as column-numbers.
  This is the check that ties the two readings together; a digit dropped by
  either one shows up here.
- One column-number per column of a block, and no block narrower than its own
  numbers.
- **Decomposition**: `part2 == part1 + Σ(problem_ceph − problem_prec)`, i.e.
  the two totals differ by exactly the sum of the per-problem differences
  (`7229350537438 + 4249918466112 == 11479269003550`).
- Both totals present and non-zero *before* anything compares them (a check
  that compares two absent values passes), both inside 2^62, and part 1 at
  least the largest single problem.
- Six malformed worksheets are each rejected with a message: operator row not
  last, two operators in one problem, a letter inside a number, a row holding
  neither, an all-blank sheet, and operators mixed among the numbers.

### Defect injection: 17 defects, 16 caught, 1 missed

`./inject.py` breaks the solver on purpose, one single-token edit at a time,
in a scratch copy — the real source and binary are never touched — and records
whether `--check` notices. It first re-runs the unmutated baseline and refuses
to report anything if that does not build clean and pass, because "caught"
means nothing otherwise. Matrix:

| # | defect | verdict |
|---|---|---|
| 1 | `9` is not treated as a digit | CAUGHT, 9 checks (first: the statement example fails to parse) |
| 2 | the row-run scan steps two columns at a time | CAUGHT, trap: index out of bounds |
| 3 | the blank-skipping scan steps two columns at a time | CAUGHT, 11 checks (first: `123*45*6 = 3690`, statement says 33210) |
| 4 | every block stops one column early | CAUGHT, trap: index out of bounds |
| 5 | every block starts one column late | CAUGHT, trap: index out of bounds |
| 6 | part 1's run starts from 1, not the first operand | CAUGHT, 13 checks (first: `123*45*6 = 270`) |
| 7 | the last product of every problem is thrown away | CAUGHT, 14 checks (first: `123*45*6 = 0`) |
| 8 | part 1's `*` becomes `+` | CAUGHT, 10 checks (first: `123*45*6 = 174`) |
| 9 | part 1's `+` becomes `*` | CAUGHT, 10 checks (first: `328+64+98 = 98`) |
| 10 | the identity fold starts every `+` from 1, in all three folds | CAUGHT, 10 checks (first: part 1's three methods disagree) |
| 11 | a column's digits are added instead of built into a number | CAUGHT, 11 checks (first: block 0 reads `[14 6 1]`, published `356 24 1`) |
| 12 | part 2 counts the operator row as a digit row | CAUGHT, 11 checks (first: block 0 reads `[356 24 4]`) |
| 13 | part 2 reads a block's columns left to right | CAUGHT, 2 checks (first: block 0 reads `[1 24 356]`) |
| 14 | the operator row is re-tested with a condition that cannot be false | **MISSED** — see below |
| 15 | numbers longer than two digits are rejected | CAUGHT, 7 checks (first: the example fails to parse) |
| 16 | the last problem is dropped from part 1's total | CAUGHT, 11 checks (first: part 1 total 4277155, statement says 4277556) |
| 17 | the part 1 total walks one problem past the end | CAUGHT, trap: index out of bounds |

**The one that was not caught is honest and reported rather than omitted:**
defect 14 changes `if (nd == 0)` to `if (nd == 0 && no > 0)` in the row
classifier. A row holding neither digits nor operators was already rejected
a few lines above, so `no > 0` cannot be false there and the edit is a
**semantic no-op** — it alters no answer, no diagnostic and no count, so no
property can see it. It is in the table to show the harness reports misses
instead of hiding them.

**Defect 13 is the interesting one.** Reading the columns left to right
instead of right to left cannot change any total, because `+` and `*` are
commutative — a *value* cross-check is structurally blind to it. Only the
anchor that pins the published **order** of the cephalopods' numbers
(`356 24 1`) catches it. That is the difference between checking an answer
and checking an interpretation.

Four defects (2, 4, 5, 17) are caught by a **trap** rather than by an
assertion — the mutated program reads out of bounds. That is the intended
behaviour, not a defect in the check: Y traps on an out-of-bounds index, the
trap line goes to stdout where the gate's item 3 and a non-zero exit both
see it, and none of them silently produced a wrong number.

## Compiler workarounds

Every one of these is visible in the code, at the line cited.

1. **`str +=` inside an `if` arm needs an explicit `;`** — `ceph_line`, one
   character. Without it the arm is a *value-used* position, the emitter
   falls back from the amortised `y_str_app` to an exact `y_str_cat`, and the
   loop becomes quadratic in the block's width. Measured here on 40 000
   one-byte appends: **243 ms and 3.2 GB of arena without the `;`, 0.54 ms
   and 1.46 MB with it** — same bytes out. Already filed, not by me, as the
   heading `A str += in a value-used position makes its whole loop O(n²) in heap — one missing semicolon turns 1.2 MB of output into 1.2 GB of allocation`
   in `examples/BUGS.md` (with the backticks and superscript as printed
   there); that filing's minimal reproduction is literally this shape
   (`if (i % 2 == 0) { s += "..." }` with no `;`), so I did not file a
   duplicate. `NATIVE.md`'s "Owned strings" section documents the rule this
   works around.

   I audited the whole program rather than eyeballing it: compiled with `-S`
   and counted `call y_str_app` (the in-place amortised append) against
   `call y_str_cat` (the exact-size copy) per function. `ceph_line` is now
   **2 app / 0 cat**. Every remaining `cat` in the binary is in an error
   message or in an f-string built for a `print` — `parse` 11, `solve` 34,
   the check functions 6–64 each — and none of them is inside a loop.

2. **`if` arms must agree in type or the `if` becomes void** — `cell`. The
   function returns `long`; `if (c < line.length) { v = line[c] }` with `v`
   a `long` and `line[c]` a `byte` makes the arms disagree, and the whole
   `if` is void, which is a compile error against the declared return type.
   Widening the byte arm explicitly (`v = line[c] + 0`) fixes it. This is the
   documented VOID law, not a bug.

3. **A `def` must be declared before use** — `if_then` sits above
   `check_real`, which uses it in an f-string.

4. **No out-parameters.** `parse_col` needs to return both a value and the
   number of digits it read (`"007"` is 7 but three digits), so the digit
   count goes through a module-level `g_clen` rather than a second return
   value. The parse accumulators (`a_vals`, `a_cvals`, …) are likewise
   module-level arrays reset at the top of every `parse`, which also keeps
   `add_problem`'s signature down to two arguments.

Nothing is filed from this example beyond the citation above: the two
compiler behaviours I ran into are both already documented, and one of them
is already filed.

## Files

| file | what |
|---|---|
| `day06.y` | the whole example — parser, both readings, property battery, `--bench` |
| `input.txt` | the vendored puzzle input (**gitignored**: per-account personal data) |
| `EXPECTED` | the golden stdout of `./day06`, byte for byte |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |
| `inject.py` | the defect-injection harness (17 defects) |
| `.gitignore` | keeps `input.txt` out of git |
| `README.md` | this file |

No toolkit file is vendored: this example is a filter, not a terminal
program, so `fx.y`/`tui`/`args` are all unused and none
of their shas are recorded.

## Self-containment

`day06.y` imports only `fs` (the compiler's own std module) and reads exactly
one file, `input.txt`, from the working directory. There is no cross-day
import, no `embed`, and no shared state: the folder builds and passes with
every other `aoc/dayNN` deleted. The input is a copy of
`examples/aoc/inputs/day06.txt`; no session cookie is in any file here, and
the input appears nowhere but `input.txt`, which `.gitignore` excludes.

## Traps this example avoids, and how

- **Runtime traps print to stdout**, so a trap would silently corrupt
  `EXPECTED` instead of failing. Every error path — unreadable file, missing
  operand, `--input` with no argument, unknown option, two input files, six
  malformed worksheets — writes a message to **stderr** and exits **1**:
  `exit(main())`, because `main()`'s return value is not the exit status.
- **No literal array or record inside a loop body.** Every literal in
  `parse` and `add_problem` is outside every loop; the accumulators are
  grown with `+=` (amortised, in place).
- **`split()` drops one trailing empty field** and `sep.join` puts the
  separator first — the parser never uses either. It walks columns and
  character ranges directly, which is what part 2 needs anyway: part 1's
  information (which row a digit came from) and part 2's (which column) have
  to survive parsing, and a whitespace-splitting parser destroys one of them.
- **Ragged rows are the norm, not an error.** `cell()` reads past a short
  row as blank paper, which is why the statement's example parses at all
  (its operator row is two columns shorter than its number rows).
- **`MAX_DIGITS = 18`** rejects a number too long for a `long` rather than
  silently wrapping. A block whose column holds no digits at all is reported
  too, rather than skipped — the statement never produces it, and inventing
  an answer for it would be worse than refusing.
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
