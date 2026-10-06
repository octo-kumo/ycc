# `aoc/day05` — Advent of Code 2025, day 5 "Cafeteria", in Y

A self-contained solver for [AoC 2025 day 5](https://adventofcode.com/2025/day/5),
both parts, plus a property battery that does not consult a single reference
file.

```
cd examples/aoc/day05
../../../refs/ycc.ref day05.y -o day05     # build (THREE .. -- see below)
./day05                                   # both answers
./day05 --check                           # the property battery
./day05 --help
```

## Answers

| | |
|---|---|
| **part 1** — available ingredient IDs that are fresh | **739** |
| **part 2** — distinct ingredient IDs the ranges cover | **344486348901788** |

Supporting figures the run prints: 182 ranges, 1000 available IDs, 78 merged
segments, and 91 261 894 212 606 integers that the raw range lengths count
twice.

## The puzzle, in my own words

The elves' new inventory system is a database. It is two sections: a list of
**fresh ingredient ID ranges**, a blank line, then the list of **available
ingredient IDs** the kitchen actually has.

A range is **inclusive** — `3-5` means IDs 3, 4 and 5. Ranges may **overlap**,
and an ID is fresh if it falls inside *any* range, however many.

- **Part 1** asks how many of the available IDs are fresh. Spoiled ones do not
  count.
- **Part 2** asks how many distinct ingredient IDs the *ranges* cover
  altogether — the size of their union. The available IDs are irrelevant to
  it, and a doubly-covered integer counts **once**.

The statement's own worked example is a database of ranges `3-5`, `10-14`,
`16-20`, `12-18` over the available IDs `1, 5, 8, 11, 17, 32`. The statement
says **3** of the available IDs are fresh (5, 11 and 17; 17 is in two ranges
and counts once), and that is part 1's anchor.

## Where part 2 came from — read this before trusting the answer

**Part 2's wording is not in the statement.** Part 2 of every AoC day is
login-gated, so an unauthenticated fetch of the day-5 page returns part 1
only. I fetched that page **once** and did not retry.

Part 2's definition therefore comes from **a public write-up, not from AoC**:

- **primary source** — Minindu Rupasinghe, *Advent of Code 2025 Day 5:
  Cafeteria*, DEV Community, 10 December 2025,
  <https://dev.to/kryko7/advent-of-code-2025-day-5-cafeteria-4m7k>. It states
  part 2 as "how many total IDs do these ranges cover", and for the
  statement's example it gives **"Total IDs covered by ranges: 14"**.
- **two independent corroborations of the same reading** (all fetched the same
  session, none from AoC):
  - Todd Ginsberg, *Advent of Code 2025 - Day 5, in Kotlin - Cafeteria*,
    5 December 2025, <https://todd.ginsberg.com/post/advent-of-code/2025/day5/>
    — sorts the ranges, folds overlapping ones together, then
    `ranges.sumOf { it.last - it.first + 1 }`.
  - Joshua Chen, *Advent of Code 2025 Day 5: Cafeteria*,
    <https://joshcena.com/notes/aoc/2025/5/> — sorts by start and adds only
    the non-overlapping part of each subsequent interval.

### The two anchors, and how confident that makes the answer

| anchor | value | source | asserted by |
|---|---|---|---|
| part 1 on the statement's example | **3** | the AoC statement itself | `micro M1 statement example` |
| part 2 on the same example | **14** | the write-up above | `micro M1 statement example` |

`--check` runs the solver on the statement's own example database and asserts
**both** values. 14 is what you get by hand: `3-5` ∪ `{10-14, 12-18, 16-20}` is
`{3,4,5} ∪ {10..20}`, which is 3 + 11 = 14. So the implementation reproduces
part 1's published answer and part 2's published answer **on the same input**.

How confident should a reader be?

- **High** on the *interpretation*: three independent write-ups agree on the
  wording, and the value 14 is arithmetically forced by the example's ranges
  under that reading. My reading reproduces both published values.
- **Not proven from AoC itself**: if the real part 2 asked something adjacent —
  the union *intersected with the available IDs*, or the count of distinct
  ranges after merging — then 344486348901788 would be wrong while every
  assertion in this README still passed. For the record, the union
  intersected with the available IDs would be 739 (the part-1 answer) and the
  merged range count would be 78; neither is what I report. I am flagging the
  residual risk rather than claiming it away.

## The input

Vendored from `examples/aoc/inputs/day05.txt` into **`input.txt`** in this
folder, byte-identical (sha256 `674c46f861a06b0de4429a600c8dc34e5b7e4408e8a9cde8218fbc9278b9aa91`),
so the folder builds and passes with every other day deleted. It is
per-account personal data, so `.gitignore` in this folder keeps it out of git
— the repo's own `!examples/**/*.*` rule would otherwise re-include it. No
session cookie appears in any file here.

Shape, measured rather than assumed (`awk` on the file):

- **1183 lines, 21 535 bytes.** Line 183 is blank; it is the **only** blank
  line.
- lines 1–182: **182 ranges**, `lo-hi`, every one with `lo <= hi`, no
  whitespace anywhere in the file. 16 of them are a single integer (`x-x`), 6
  pairs are byte-identical repeats, and 41 ranges sit inside another range.
  The list is **not** already sorted.
- lines 184–1183: **1000 bare IDs**, all distinct, no `-` anywhere in this
  section.
- magnitudes: IDs run 100 800 563 636 … 562 608 625 073 939, range ends run
  3 777 222 335 448 … 561 691 222 663 012. Everything fits a `long` (the
  largest is 2^49); the parser still refuses more than 18 digits so a longer
  value can never wrap silently.

So the ranges' lengths sum to 435 748 243 114 394 — **4.4 × 10^14 integers**.
Enumerating the union is not an option, which is the whole point of the day.

## The algorithm

**Part 1**, computed two ways and required to agree:

| method | what it does |
|---|---|
| `part1_scan` | the statement's own walk — for every available ID, ask every range in the order the file gave them. No sorting at all: 1000 × 182 tests. |
| `part1_binary` | one binary search per ID over the merged segments. |
| `part1_set` | membership in the explicitly expanded set of covered integers (micro-cases only). |

**Part 2**, computed four ways and required to agree:

| method | what it does |
|---|---|
| `part2_merge` | sum `hi - lo + 1` over the merged segments. |
| `part2_accum` | one pass over the sorted raw ranges keeping only the furthest end seen so far; builds no array. |
| `part2_sweep` | the endpoint sweep: a range contributes an event at its first integer and one at one past its last, and the covered integers are counted between consecutive events. |
| `part2_expand` | the brute force — materialise every covered integer, sort, count the distinct ones. Uses the **raw** ranges and its own sort; `merge_ranges` appears nowhere in it. Only for inputs small enough to materialise. |

**No `sort` in Y**, so there are two hand-written sorts:

- `msort` — bottom-up merge sort over a `[long]`, scratch buffer filled once
  by the caller, no recursion.
- `sort_pairs` — the same shape over **parallel** `lo`/`hi` arrays, ordering
  by the pair. This cannot be an encoding: each end of a real range is about
  2^49, and two of them do not fit in one `long`, so the comparison has to see
  both halves. Filed as
  [SUGGESTIONS.md #17](../SUGGESTIONS.md#17-there-is-no-sort-and-no-way-to-pass-a-comparison-so-sorting-twice-costs-sixty-lines--and-the-pair-sort-cannot-be-expressed-at-all).

Two details that are easy to get wrong and are asserted directly:

- **`merge_ranges` joins ranges that merely *touch*** — `1-3` and `4-6` cover
  `1..6` with no gap, so the test is `lo[i] <= cur_hi + 1`. Dropping the `+1`
  still sums to the right total and is still not a merge, which is why
  `seg_wellformed` asserts **maximality** (no two segments may be adjacent)
  rather than only the total.
- **`part2_sweep` counts a span when the depth is *positive***, not by the
  depth. Integrating the depth counts a doubly-covered integer twice: on the
  statement's own example that is **20 instead of 14**.

## The property check — `./day05 --check`

`109 checks, all passed`. No reference file is involved. Nothing here compares
against `EXPECTED`.

### 1. Hand-worked micro-cases (12)

Each is a tiny database written as literal **lines**, so the real parser runs
too. The arithmetic, so a reader can check it by eye:

| # | ranges / ids | part 1 | part 2 arithmetic |
|---|---|---|---|
| **M1** | the statement's example: `3-5, 10-14, 16-20, 12-18` / `1, 5, 8, 11, 17, 32` | **3** | merged `{3,4,5}` ∪ `{10..20}` = 3 + 11 = **14** |
| M2 | `1-3, 4-6` / `3, 4, 6` | 3 | `{1..6}` = **6** — ranges that only *touch* must be **one** segment |
| M3 | `10-20, 12-14` / `11, 13, 15` | 3 | `{10..20}` = **11** — the nested range stretches the segment; 13 is in both and counts once |
| M4 | `7-9, 7-9` / `7, 8, 9` | 3 | **{7,8,9}** = **3**, not 6 — an identical repeat must not double the union |
| M5 | `100-100` / `99, 100, 101` | 1 | **{100}** = **1** — a single-integer range |
| M6 | `10-20` / `0, 9, 10, 20, 21` | 2 | **{10..20}** = **11** — both ends **inclusive**, and below/above are spoiled |
| M7 | `0-0` / `0` | 1 | **{0}** = **1** — the smallest database there is |
| M8 | `2-3, 6-7, 10-11` / `3, 7, 11, 4` | 3 | 2 + 2 + 2 = **6**, three segments, no merging wanted |
| M9 | `20-30, 1-2, 10-12` / `11, 25, 3` | 2 | 11 + 2 + 3 = **16** — unsorted input |
| M10 | `5-6, 8-9` / `5, 6, 7, 8, 9` | 4 | 2 + 2 = **4** — 7 is a one-integer gap and spoiled |
| M11 | `1-2, 2-3, 3-4` / `0, 1, 4, 5` | 2 | **{1..4}** = **4** — a chain of touching ranges is one segment |
| M12 | `0-1000, 5000-5000` / `0, 1000, 1001, 5000, 1` | 4 | 1001 + 1 = **1002** |

M2, M3, M4, M5, M6, M10 and M11 are the edge cases the statement calls out
(overlapping, nested, inclusive ends, spoiled IDs, and an ID in two ranges
counted once). M7 is the degenerate case that would trap a `ev[0]` or a
`lo[0] - 1` on an empty array.

Every micro-case runs **all seven methods** on it and asserts they agree, plus
that the segments are well formed and partition the ranges.

### 2. Independent cross-checks

- **Brute force against efficient, on the same quantity.** `part2_expand`
  materialises every covered integer and counts the distinct ones, sharing no
  code with the merge: different input (raw ranges vs merged), different sort,
  different counting. `part1_set` does the same for part 1.
- **Three more algorithms for part 2.** merge-and-sum, the furthest-end
  accumulator, and the endpoint sweep are structurally different; they share
  only the sort.
- **Two algorithms for part 1.** the statement's linear scan, and a binary
  search over merged segments.
- **The parser against a second reader of the same bytes.** `rescan` walks the
  raw file tracking only digit runs and separators, deciding which section it
  is in by meeting a newline with no digits in front of it. It never sees a
  line and never calls the parser. Agreement on 182 ranges, 1000 IDs, the sum
  of raw lengths, the sum of IDs, the dash count and both extremes is
  independent evidence that the parser read the file the same way twice.
- **Every ID through `tolong`** as well as through the hand-rolled acceptance
  test in `num_reason`.

### 3. Whole-state-space proofs, not samples

- **All 22 736 databases of one to three ranges** over the universe
  `[a,b] with 0 ≤ a ≤ b ≤ 6` — that is the 28 ranges, every ordered pair
  (28² = 784) and every ordered triple (28³ = 21 952). This is the
  *complete* state space, so "disjoint, nested, duplicated, touching and
  identical ranges in every arrangement" is a claim about all of it, not a
  sample. Each case runs all seven methods against each other and against the
  invariants below: **0 failed checks**. A fixed probe set of 9 IDs (`-1`
  through `7`) covers one-below, every interior value and one-above.
- **Every permutation of six values** and of three multisets with repeats:
  1584 orderings, each required to come out of `msort` ascending **and**
  carrying the same multiset. A sort that shuffles fails the second half.
- **Every permutation of three sets of ranges**: 246 orderings through
  `sort_pairs`, required to come out ordered by `(lo, hi)` and carrying the
  same multiset of ranges. This one exists because of a real bug — see
  *Defects this check caught* below.

### 4. Invariants asserted on the real input

- merged segments are **disjoint, ascending and maximal**, and there are
  exactly 78;
- the segments are a **partition** of the ranges: every raw range sits inside
  exactly one segment, and every segment contains at least one raw range —
  nothing dropped, nothing counted twice;
- the union ≤ the sum of the raw lengths (344 486 348 901 788 ≤
  435 748 243 114 394) and ≤ the span from the lowest low to the highest high
  (≤ 557 914 000 327 565); the difference is exactly the 91 261 894 212 606
  integers the raw lengths count more than once;
- fresh + spoiled = 739 + 261 = 1000; part 1 ≤ the number of IDs asked about;
- **monotonicity**: adding one copy of an already-fresh ID raises part 1 by
  exactly 1 (739 → 740);
- 186 of the IDs are covered by two or more ranges and are still counted
  once each;
- dropping all 6 duplicate ranges leaves the union and the segment count
  **exactly where they were** — 176 distinct ranges, same 78 segments, same
  344 486 348 901 788.

### 5. Guarding against a vacuous pass

Two agents in this campaign shipped checks that compared two *absent* values
and passed, so:

- **Every observed quantity is shown present and non-zero before it is
  compared.** `ranges present`, `ids present`, `segments present`,
  `raw_total present`, `rescan present`, `part 1 present`, `part 2 present`.
  These are separate assertions, not part of a conjunction.
- **The expected counts come from outside the code under test.** They are
  constants in the source (`X_*`), established by reading `input.txt` with
  `awk` and `python3` and writing the numbers down — see *External facts*
  below. Injection 14 edits one of them by one and the battery objects.

### External facts (`X_*` in the source)

Established outside this program, with `awk` and `python3`, from the file as
shipped:

| constant | value | how |
|---|---|---|
| `X_RANGES` / `X_IDS` | 182 / 1000 | `awk` line ranges either side of the blank line |
| `X_DISTINCT_IDS` | 1000 | `python3 len(set(ids))` |
| `X_RAW_TOTAL` | 435 748 243 114 394 | `python3 sum(b-a+1)` |
| `X_UNION` | 344 486 348 901 788 | `python3` sorted merge, written from the statement, not from this code |
| `X_SEGS` | 78 | the same merge |
| `X_FRESH` / `X_SPOILED` | 739 / 261 | `python3` linear scan |
| `X_MIN_LO` / `X_MAX_HI` / `X_SPAN` | 3 777 222 335 448 / 561 691 222 663 012 / 557 914 000 327 565 | `python3 min`/`max` |
| `X_DASHES` | 182 | `python3` count of `-` |
| `X_SINGLE` / `X_CONTAINED` / `X_DUP_PAIRS` | 16 / 41 / 6 | `python3` |
| `X_MULTI` | 186 | `python3` count of IDs in ≥ 2 ranges |

`X_UNION` and `X_FRESH` are an **independent second implementation** — a
throwaway `python3` solve written from the statement — so they are a genuine
cross-check of the algorithms rather than a copy of this program's output.
They are *not* what makes the check non-vacuous: the micro-cases, the
whole-state-space proof and the injection runs do that.

### Defects this check caught

`inject.sh` mutates a **copy** of `day05.y` with `sed`, rebuilds with the
pinned compiler, and **requires `--check` to fail**. `day05.y` itself is never
touched. Run it with `./inject.sh`.

**20 defects injected, 20 caught, 0 missed.**

| # | injected defect | caught by |
|---|---|---|
| 1 | `msort`'s first pass merges runs of **2** instead of 1 | 18 FAILs — `micro M1 part 2 13 == 14` |
| 2 | `merge_ranges` drops the `+1`, so touching ranges never join | `micro M2 … segments well formed` |
| 3 | a nested range stops extending the segment | 19 FAILs — `micro M1 part 2 13 == 14` |
| 4 | `part2_sweep` integrates the depth instead of the indicator | `micro M1 … part 2 methods agree` |
| 5 | `seg_of` uses `<` where it must be `<=` | 9 FAILs — `micro M4 … part 1 methods agree` |
| 6 | `in_segments` uses `<` on the upper end | 11 FAILs — `micro M1 … part 1 methods agree` |
| 7 | `part1_scan` makes the lower end exclusive | 17 FAILs — `micro M2 part 1 2 == 3` |
| 8 | `expand_all` drops its sort, so the repeat filter misses repeats | 4 FAILs — `micro M1 … part 2 methods agree` |
| 9 | `rescan` never clears `want_high`, counting every range twice | `rescan present ranges=363` |
| 10 | `expand_all` drops the top integer of every range | 23 FAILs |
| 11 | `part2_accum` starts `end` one integer too high | 14 FAILs — `micro M1 … part 2 methods agree` |
| 12 | `merge_ranges` never pushes the final segment | 67 FAILs — `micro M1 part 2 3 == 14` |
| 13 | a **micro-case's expected value tampered with** (M2: 6 → 5) | `micro M2 part 2 6 == 5` |
| 14 | an **external fact tampered with** (`X_RAW_TOTAL` off by one) | `raw_total present` |
| 15 | the permutation oracle itself weakened (`>=` for `>`) | `msort sorts every permutation` |
| 16 | `rescan` keeps only the first range's low end | `parse == rescan: extremes` |
| 17 | a new segment starts one integer late | 23 FAILs — `micro M1 part 2 13 == 14` |
| 18 | `part1_scan` counts the **spoiled** IDs — a wrong answer, not a broken helper | 25 FAILs — `micro M2 part 1 0 == 3` |
| 19 | `part2_merge` uses `+2` for an inclusive range | 28 FAILs — `micro M1 part 2 16 == 14` |
| 20 | `part2_merge` uses `+0` for an inclusive range | 28 FAILs — `micro M1 part 2 12 == 14` |

Injections 13 and 14 exist because a battery that "agrees" with an edited
expectation is worthless: 13 shows the micro-cases are really asserted rather
than echoed, and 14 shows the pinned external constants are really compared.

Three of these were **my bugs, found before the example was finished**, and
none of them is a compiler bug:

1. `sort_pairs` originally interleaved `(lo, hi)` into one `[long]` and sorted
   the *values*. That compiles, sorts, and yields an ascending array — and it
   is wrong, because sorting values pulls the two smallest into a "pair". It
   reported **144** merged segments and a part-2 answer of
   **256 288 138 474 184**, and *every part-2 method still agreed*, because
   summing scrambled intervals that happen to be in ascending low order still
   adds up. Only `check_pair_permutations` (246/246 orderings) could see it.
   This is what `SUGGESTIONS.md` #17 is about.
2. `msort`'s first pass started at run width 2 instead of 1 — a merge step may
   only join two runs that are *each already sorted*.
3. `rescan` never cleared its "expecting a high end" flag, so it counted 363
   ranges instead of 182. Caught by the `parse == rescan` assertions, which is
   the entire reason for a second reader of the same bytes.

## Error and argument paths — no trap on any of them

Runtime traps print to **stdout** here, so a trap would silently corrupt
`EXPECTED` instead of failing. Every one of these prints a message on stderr
and exits **1**, verified end to end (0 traps):

| invocation | message |
|---|---|
| a missing file | `cannot read missing.txt` |
| `--input` with no name | `--input needs a file name` |
| `--bogus` | `unknown option --bogus (try --help)` |
| two input files | `more than one input file given (try --help)` |
| an empty file | `the file is empty` |
| no blank line | `no blank line separating the ranges from the IDs` |
| two blank lines | `more than one blank line; the statement gives exactly one` |
| blank line first | `no fresh ranges before the blank line` |
| file ends with a blank line | `the file ends with a blank line, so it holds no available IDs` |
| `x-9` | `line 2: lower end not a bare number` |
| `9-3` | `line 2: lower end 9 is above the upper end 3` |
| `3` (no dash) | `line 2: no '-' between the two ends` |
| `3-` | `line 2: upper end empty` |
| `-5` | `line 2: lower end empty` |
| `3-5-7` | `line 2: upper end not a bare number` |
| a non-numeric ID | `line 4: not a bare number` |
| a 20-digit ID | `line 4: more than 18 digits (a long could overflow)` |
| a line of spaces where the blank should be | `no blank line separating the ranges from the IDs` (a space is not a blank; the parser is strict) |

**Accepted, and checked:** a CRLF file (one trailing `\r` per line is stripped),
a file with no trailing newline, a file with extra trailing newlines,
`0-0` over `0`, and IDs with leading zeros.

## Numbers

| | |
|---|---|
| build | 0 warnings from the pinned compiler |
| run (`./day05`) | **under 10 ms** wall clock, 2 060 KB peak RSS |
| run (`./day05 --check`) | **~40 ms** wall clock, 49 MB peak RSS |
| whole-state-space proof alone | **30 ms**, **46 925 KB** of arena for 22 736 databases (~2.1 KB each: six arrays plus two scratch buffers per case, never freed) |
| memory | every process under `ulimit -S -v 3670016` (3.5 GiB); peak is 1.4 % of the cap |
| allocation in the default run | no loop over the input builds a literal or a string; the probe-ID array and the permutation bases are built outside every loop. `--check` asserts the proof's arena really grew (`the state-space proof really ran`), so a heap that did not move can never be reported as a passing proof |
| `EXPECTED` | 234 bytes, identical over two runs |

The quadratic-append audit (`call y_str_app` = amortised in-place, `call
y_str_cat` = exact-size copy) shows `y_str_cat` only in message-building
functions — `expect`, `micro`, `check_real`, `solve`, `run_check`,
`range_reason`, `num_reason`, `parse_db` — each called a bounded number of
times (108 assertions, not per input line). No `+=` builds a message inside a
loop over the input.

## Toolchain and pin

- **Compiler pin:** `../../../refs/ycc.ref`, sha256
  **`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`**.
  The pin moves on every rebless; if `EXPECTED` stops reproducing under a new
  one, rebuild, re-run, and record the new sha here.
- **Three `..`, not four.** `examples/aoc/day05` → `examples/aoc` →
  `examples` → repo root. Four resolves to `examples/refs/ycc.ref`, which does
  not exist.
- **No vendored toolkit.** This example needs no `fx.y` and none of the std
  units — it is a batch program with no terminal, no clock and
  no floating point. It uses only the standard `fs` unit (`import fs;`), which
  ships with the compiler, so there are no vendored-file shas to record.
- The input is the only vendored file: `input.txt`, sha256
  `674c46f861a06b0de4429a600c8dc34e5b7e4408e8a9cde8218fbc9278b9aa91`.

## Language constraints this example works around

None of these is a compiler bug; each is a documented property of Y.

| constraint | how this example lives with it |
|---|---|
| no `sort` builtin | two hand-written bottom-up merge sorts, `msort` and `sort_pairs`. Filed as [SUGGESTIONS.md #17](../SUGGESTIONS.md#17-there-is-no-sort-and-no-way-to-pass-a-comparison-so-sorting-twice-costs-sixty-lines--and-the-pair-sort-cannot-be-expressed-at-all). |
| no `min` / `max` builtin | `imin`, used on every merge iteration. Named in the same filing. |
| no `break` / `continue` | every early exit is a guard flag with an explicit terminal assignment (`bad`, `inside`, `hit`, `more`, `nrng`); every "continue" is a positive condition around the body. |
| no `float` → `long`, no cast syntax | no floating point at all; the sweep's events are `2*lo` / `2*(hi+1)+1` in `long`. |
| `[0; n]` needs a literal size | scratch buffers are filled by `for _i in 0..n { tmp += 0 }`, once per call. |
| a literal array inside a loop body allocates per iteration | the probe-ID array and the permutation bases are built **outside** every loop; the generated proof cases allocate their range literals per *case*, which is the 22 736-case cost and is measured above. |
| the heap is an arena | every array is grown with `+=` (amortised O(1) doubling); nothing is freed and the total stays under 50 MB even for the whole-state-space proof. |
| `main()`'s return value is not the exit status | `def main() -> long { … }; exit(main());`, so an error path really exits 1. |
| `split()` drops one trailing empty field | not used for the parse — the parser indexes lines directly, so a trailing empty line is handled explicitly by `eff_lines`. |
| `.length` is a property | used as a property throughout. |

## Files

| file | |
|---|---|
| `day05.y` | the whole example: parser, four part-2 methods, two part-1 methods, the rescan, and the property battery |
| `input.txt` | the vendored AoC input, gitignored |
| `.gitignore` | keeps `input.txt` out of git |
| `EXPECTED` | 234 bytes, the deterministic run's stdout |
| `gate.conf` | `build=`, `run=`, `check=` |
| `inject.sh` | the 20 defect injections; requires `--check` to fail on each |
| `README.md` | this file |

## Acceptance gate

```
python3 ../../gate.py aoc/day05        # from examples/aoc
```

9/9, including item 8, which runs `./day05 --check` (the `check=` line in
`gate.conf`) — the gate does not take this file's word for anything.
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
