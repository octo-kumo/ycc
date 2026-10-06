# day08 — Advent of Code 2025, day 8 ("Playground"), in Y

## The puzzle, in my own words

A list of **junction boxes** hangs in 3D space over a playground, one box per
line, each given as `X,Y,Z`. Wires (strings of lights) are run between pairs of
boxes; electricity passes along a wire, so boxes joined by wires form a
**circuit** — and a circuit is exactly a *connected component* of the graph of
wires. The Elves want the boxes wired **shortest wire first**: take every pair
of boxes, order the pairs by straight-line distance, and connect them in that
order. A pair whose two boxes are already in one circuit changes nothing.

The two questions:

* **Part 1** — wire the **1000 closest pairs**, then multiply together the
  sizes of the **three largest circuits**.
* **Part 2** — keep wiring shortest-first **until every box is in one circuit**,
  then multiply together the **X coordinates of the last pair you connect** (the
  pair whose connection leaves a single circuit).

The statement's own worked example (the 20 positions it lists) uses the **ten**
shortest connections; the statement says so explicitly, and says the real input
uses 1000 connections.

## Build and run

```
cd examples/aoc/day08
../../../refs/ycc.ref day08.y -o day08     # three "..": day08 -> aoc -> examples -> root
./day08                                    # both answers, from ./input.txt
./day08 --check                            # property battery (106 checks)
./day08 --help
```

Optional flags: `--input FILE` (read another input), `--pairs K` (wire K
closest pairs instead of 1000). Both default-run paths are deterministic: no
clock, no terminal size, no network, no `--seed`.

Pinned compiler: **`refs/ycc.ref`, sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`**. The pin
moved **during** this day's work (`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`
→ the sha above): the gate caught it at item 0, so the binary was rebuilt with
the new pin and everything re-run — identical output, identical answers,
identical 106/106 check, identical defect-injection matrix. If `--check` or the
answers ever stop reproducing, re-read the sha, rebuild and re-record. Nothing
here was built with anything else.

## The answers (from this folder's `input.txt`)

```
part 1  answer 1 = 66640
        the 1000 shortest connections leave 265 circuits; 735 of those 1000
        connections joined two circuits into one; the three largest are
        56, 35, 34  ->  56 * 35 * 34 = 66640
part 2  answer 2 = 78894156
        the connection that leaves a single circuit is the 3642nd of the
        ordered pairs: box 715 (X = 4731) and box 987 (X = 16676)
        ->  4731 * 16676 = 78894156
```

Runtime **0.35 s** wall clock for the real input (1000 boxes, 499 500 pairs:
the pair keys, a full radix sort of all of them, and 499 500 union–find
steps); `--check` takes 2.4 s because it also runs the full heap sort and the
flood fills. Peak RSS **≈ 30 600 KiB** (30 564–30 612 over three runs), and
that is *all* of the program's memory: the
buffers are module-level fixed arrays, sized up front, so the solve loop
allocates nothing (see "No allocation in the loop" below). Runs inside the
campaign's `ulimit -S -v 3670016` with room to spare.

Both answers were also computed by a throwaway Python union-find written
independently of this program (read the input, sort `sqrt`-free squared
distances, union, report). It agreed on **every** quantity: 66640, the three
largest 56/35/34, 265 circuits, 735 merges, an unambiguous cut, part 2 =
78894156 from the 3642nd pair, boxes 715 and 987, X 4731 and 16676. That script
is not part of the folder; the in-process cross-checks below are.

## Where part 2 came from, and how confident the anchor is

**Part 2 is login-gated.** `https://adventofcode.com/2025/day/8` returns only
part 1 (one `<h2>`, one puzzle, then a login prompt) — verified by fetching it
once, as the brief asks, without retrying. So part 2's definition is **not from
AoC**. It is from reputable public write-ups, which agree:

* <https://aoc.winslowjosiah.com/solutions/2025/day/8/> — union-find over the
  distance-sorted pairs; part 2 is "keep looking at pairs until every box is
  connected into a single circuit", and the answer is the product of the two
  boxes' `X` coordinates (`part_2 = box1[0] * box2[0]`).
* <https://donaldh.wtf/2025/12/2025-aoc-day-8-playground/> — quotes the
  official part-2 wording ("continue connecting the closest unconnected pairs
  until they're all in the same circuit … multiply together the X coordinates
  of the last two junction boxes you need to connect") and asserts **25272** for
  the statement's example input.
* <https://baerentsen.space/aoc-2025-day-8/> and
  <https://gitsith.com/aoc/2025/08> — both describe part 2 the same way
  ("multiply the X coordinates of the final connection").

A reader should know one thing is *not* ambiguous: the two plausible readings —
"iterate every pair, a redundant one does nothing" versus "iterate only pairs
that are not already connected" — are the *same computation*, because a pair
already in one circuit cannot change the component count, so the first pair at
which the count reaches 1 is always a pair that actually merged. My program does
the former; Winslow's and Donald's do the latter; they must agree, and on the
example they do.

### Anchors — tier 1 (externally published) for both parts

| anchor | value | source |
|---|---|---|
| part 1 on the statement's own 20-box example | **40** | the statement |
| part 1's full circuit-size multiset for that example | **1×7, 2, 2, 4, 5** (11 circuits) | the statement |
| part 2 on that same example | **25272** | donaldh.wtf, asserted for his `8-test.txt` |

All three are asserted by `./day08 --check`, on the statement's own 20
positions. `--check` reproduces 40, 56→(5,4,2), 11 circuits, the exact eleven
sizes, **and 25272** — so the interpretation is externally anchored on both
sides, not just the implementation.

One caveat worth stating: donaldh.wtf's own *real-input* answers (80446 and
51294528) are for **his** account's input, not this folder's, so they neither
confirm nor contradict the numbers above. Personal AoC inputs differ per
account; that is why the anchors are the example, and why the folder carries its
own copy of the input.

## The property check (`./day08 --check`)

106 assertions, no reference file involved. A golden file proves determinism,
never correctness — and an AoC answer is a single integer that a wrong algorithm
reproduces perfectly — so the interesting assertions are these.

The assertions come from **`import test`** (`src/y/std/test.y`): `day08.y` used
to define its own `ck(name, ok, detail)` and `eq(name, got, want)` with two
tallies beside them, and both are gone — std's `test.ck` / `test.ck_eq` print and
count, the tallies are `test.checks()` / `test.failures()`, and the argument
order did not have to change because the local `ck` already read
`(name, ok, detail)`. What std does not keep is *which* assertion failed first,
so the two-line remainder of the old helper survives for that alone (and the
`FAIL, first failure:` line at the bottom still names it). `test.report()` is
deliberately not called: this file prints its own one-line summary. One visible
consequence of std printing the detail on both outcomes is the `refusal()`
helper — the eight "this input must not parse" assertions used to carry a
detail phrased as their own failure ("an empty file parsed"), which under an
`ok` line reads as a contradiction; they now say what the parser did and why.
`EXPECTED` does not move: it is the answer run, not the check.

### 1. A hand-computed micro-case, worked out in full

Five boxes on a line, so every distance is an integer (`day08.y`'s
`MICRO_LINES`); label them by their X coordinate **A**=0, **B**=3, **C**=1,
**D**=6, **E**=10, all at `y=z=0`.

Ten pairs, with distances `|dx|`:

| pair | dist | pair | dist | pair | dist | pair | dist |
|---|---|---|---|---|---|---|---|
| A-B | 3 | A-C | 1 | A-D | 6 | A-E | 10 |
| B-C | 2 | B-D | 3 | B-E | 7 | C-D | 5 |
| C-E | 9 | D-E | 4 | | | | |

Sorted shortest first (ties by pair index): **1** A-C, **2** B-C, **3** A-B,
**3** B-D, **4** D-E, **5** C-D, **6** A-D, **7** B-E, **9** C-E, **10** A-E.

* **Part 1 with k = 4** — A-C makes `{A,C}`; B-C makes `{A,B,C}`; A-B is
  already one circuit and does nothing (the statement's own case); B-D makes
  `{A,B,C,D}`. Circuits: one of 4 and one of 1, so the three largest are
  4, 1, 1 and the product is **4**. Merges: 3. Asserted as 4, 4·1·1, 2
  circuits, 3 merges, sizes summing to 5.
* **Part 2** — the next pair is D-E (4), which joins `{A,B,C,D}` to `{E}`:
  that is the connection that leaves one circuit, on the 5th pair examined.
  X_D · X_E = 6 · 10 = **60**. Asserted as 60, pair index 4, X values 6 and 10,
  5 pairs examined.
* **The pair order itself** is asserted, both as pair indices in enumeration
  order — `1, 4, 0, 5, 9, 7, 2, 6, 8, 3` — and as the box pairs those indices
  name — `A-C, B-C, A-B, B-D, D-E, C-D, A-D, B-E, C-E, A-E`. That single pair of
  assertions kills a defect in `build_keys`, in the radix sort, *and* in
  `decode_pair`, none of which the walk-based cross-check shares.

### 2. Edge cases, including ones the statement calls out

* **A pair already in one circuit does nothing** — the statement's own case,
  and it is inside the micro-case above (A-B is the third pair wired and changes
  nothing: 4 pairs, only 3 merges).
* **Fewer than three circuits** — two boxes (`0,0,0`, `4,5,6`) leave one
  circuit of 2, so the three largest are 2, 1, 1 and the product is **2**;
  part 2 is X·X = 0·4 = **0**, legitimately zero.
* **One box** — no pair at all: product 1, no final connection, no trap.
* **Two boxes at the same point** — `5,5,5`, `5,5,5`, `10,5,5`: pairs are
  (A,B)=0 and (A,C)=(B,C)=25. With k=2 the part-1 cut falls **inside a group of
  equal distances** (25 vs 25), which `--check` asserts it *detects*
  (`tie_at_cut == 1`) — and the product is 3 either way, because either tie
  resolution merges C into `{A,B}`. Part 2 = 5·10 = 50.
* **k = 0** and **k past the end** — k=0 leaves 5 circuits of 1 (product 1);
  k=999 clamps to the 10 pairs there are, giving one circuit of 5, product 5.
* **Refused inputs, each with a message and a non-zero exit, never a trap**:
  a single line (no pair), a trailing comma, two fields, four fields, a blank
  line, `4,five,6`, a lone `-`, an empty file, and more boxes than the build
  holds. A CRLF file is *accepted* (the CR is trimmed, not mistaken for a
  coordinate), and negative coordinates parse as negative.
* **The trailing-comma case is the interesting one.** `split()` drops exactly
  one trailing empty field, so `"162,817,812,".split(",")` is three fields and
  would sail through a field-count test written on `split()` alone. `day08.y`
  counts commas *in the bytes* **and** checks the split length
  (`comma_count(s) != 2 || f.length != 3`), so a trailing comma is an error
  with its line number.

### 3. An independent cross-check of the same quantity, computed two ways

`day08 --check` computes the circuit sizes a **second time by a different
algorithm**: `walk_components` flood-fills the graph of accepted pairs —
every unlabelled box seeds a fill over the `k` accepted edges — where the
answers come from union-find (`uf_parent`/`uf_size`). The two share no state
and no code except `decode_pair` (which the hand-derived pair order above
covers). Asserted equal: the component count *and* the whole ascending size
list, on the statement's example, on the micro-case, and on the real input at
k = 1000.

A second, independent check on **ordering**: `heap_order` is a binary min-heap
over all 499 500 keys, popped for *every* pair — a completely different
algorithm from the LSD radix sort that produces the answers. `--check` asserts
the two orderings give the **same key at all 499 500 positions** and the same
part 1 and part 2 answers. (Popping only the first 1000 would have answered a
different question, since part 2 needs the whole order.)

Part 2's *pair* is verified without union-find too: with the flood fill, the
prefix of pairs **before** it leaves exactly **two** components, its two boxes
are in **different** ones, and the prefix **including** it leaves exactly
**one**. So the answer is not just a number that came out of the union-find; it
is the pair that provably closed the last gap.

### 4. Invariants the answers must satisfy (real input)

* Each observation is asserted **present and non-zero before it is compared** —
  part 1 > 0, part 2 > 0, largest circuit > 0, the part-2 pair exists with two
  *different* boxes and two non-zero X values. (The brief's standing warning: a
  check that compares two absent values passes.)
* Circuit sizes sum to n (1000); `n − merges == circuits`; circuits are within
  1..n; the three largest descend and the smallest is ≥ 1; merges are within the
  k pairs.
* **The cut is unambiguous**: the 1000th pair's squared distance (65 580 174) is
  strictly below the 1001st's (65 635 702).
* **No two of the 3642 pairs that decide an answer share a distance** — so
  *neither* answer depends on how a tie was broken, and the radix sort's
  stability is a convenience rather than a hidden assumption of the result.
* **Closed form over the whole input**: wiring *every* pair leaves one circuit of
  1000 boxes, so part 1's product with k = all pairs must be exactly **n** =
  1000. Asserted, along with part 2 being unchanged by the longer cut. With
  k = 1 the product must be 2 (one circuit of 2, the rest 1s) and 999 circuits.
* Part 2 needs at least n−1 merges and no more than every pair: 3642 examined.

### 5. Defect injection — 17 injected, 16 caught, 1 equivalent

Each defect is an exact single-occurrence string replacement in a **copy** of
the source, compiled with the pin, then `./day08 --check` run against it.
("answers unchanged" means the default run still printed 66640 / 78894156 — the
check caught something the answers alone did not.)

| # | injected defect | caught | first assertion to fail |
|---|---|---|---|
| M1 | part 1 reads the state one pair early | yes | micro part 1 product — got 3, want 4 |
| M2 | part 1 reads the state one pair late | yes | micro part 1 product — got 5, want 4 |
| M3 | radix sorts only the low 32 bits (`PASSES` 6→4) | yes | heap vs radix disagree on 499 499 of 499 500 keys |
| M4 | radix scatter runs forwards (unstable pass) | yes | runtime trap: index out of bounds |
| M5 | radix bucket mask `& 255` → `& 127` | yes | example part 1 — got 30, want 40 |
| M6 | radix pass shift 8 bits → 7 | **no — equivalent** | (see below) |
| M17 | radix pass shift 8 bits → 9 (bit gaps) | yes | example circuits — got 10, want 11 |
| M7 | union adds one size too few | yes | micro part 1 product — got 1, want 4 |
| M8 | union refuses to merge equal-sized circuits | yes | micro part 1 product — got 1, want 4 |
| M9 | `decode_pair` loses the `+1` on the second box | yes | hand-derived pair order — got 10 wrong of 10 |
| M10 | part 2 multiplies a Y coordinate by an X | yes | micro part 2 — got 0, want 60 |
| M11 | part 2 records the connection *before* the one that finishes | yes | micro part 2 — got 18, want 60 |
| M12 | product of only the two largest circuits | yes | example part 1 — got 20, want 40 |
| M13 | squared distance forgets the Z axis | yes | example part 1 — got 24, want 40 |
| M14 | parse stops checking the field count | yes | "trailing comma is refused" — PARSED ANYWAY: a trailing comma |
| M15 | `merged` counts every pair, not just part 1's cut | yes | micro part 1 merges — got 4, want 3 |
| M16 | k clamped to one pair too few | yes | micro k>m clamps to all pairs — got 9, want 10 |

**The one that was not caught is not a defect, and I would rather say so than
drop it from the table.** M6 changes the radix stride from 8 bits to 7 while
the digit stays 8 bits wide, so consecutive digit windows **overlap by one
bit**. That still sorts correctly: the composition of stable passes orders the
keys lexicographically by `(d₅ … d₀)`, and for two keys the highest differing
bit always decides in the right direction — when it is a boundary bit it is the
*lowest* bit of the higher-indexed digit, whose remaining (higher) bits are
equal, so that digit decides correctly. I checked this outside the program as
well: over 300 random trials with 1–400 keys of 38 bits, the 7-bit stride
matched the true order **300/300**, while the 9-bit stride of M17 (windows that
*leave gaps* — bits 8, 17, 26, 35 uncovered) mismatched **293/300**. So M6 is
an equivalent mutant; M17 is the real version of that defect, and it is caught.

## What to look at in the code

* `radix_order` — the pair ordering the answers come from. Six stable 8-bit LSD
  passes = 48 bits, more than the 35 a squared distance needs; six is even so
  the result lands back in the caller's array (Y arrays are references, so that
  is an in-place sort).
* `sort_prefix` — the insertion sort used for the circuit sizes (at most n of
  them, so the quadratic version is the honest one; there is no `sort` in the
  language, and no `sort` was added).
* `solve` — one pass that reads both answers off: the state at pair k for part
  1, the pair at which the component count first reaches 1 for part 2.
* `walk_components` — the check's second opinion on the same quantity.
* `heap_order` / `sift_down` — the second opinion on the ordering.
* `parse_boxes` / `coord_value` — the parse, including the trailing-comma guard.

## No allocation in the loop

The heap is an arena: nothing is freed, so every byte ever allocated counts
against the cap, and a literal array or record inside a loop body would cost its
bytes *per iteration*. So every buffer here is a **fixed literal-sized array
allocated once at module level** — `pair_key`, `ord_radix`, `ord_heap`,
`radix_tmp`, `heap_buf` (524 288 longs each), the union-find and flood-fill
state (1024 or 524 288), and 256 radix buckets. `build_keys`, `radix_order`,
`solve`, `walk_components` and `heap_order` write into them and allocate
nothing: the whole program's 30 604 KiB peak RSS is those buffers plus the
input lines, and the 499 500-pair loop runs on pre-allocated memory.

The micro-case inputs in `--check` are module-level arrays too, built once.

## Language constraints worked around (no compiler bugs found)

Nothing was filed for this day: I hit no compiler defect. The obstacles were
language facts, each handled in the code rather than papered over:

* **No `sort`** — two hand-written orderings (`radix_order`, `sort_prefix`),
  cross-checked against each other. This is already filed as a missing-feature
  request, `examples/SUGGESTIONS.md` #17 ("There is no `sort`, and no way to
  pass a comparison"), so it is not re-filed here.
* **No `sqrt`, no math functions at all** — distances are **squared**, which is
  strictly monotone, so the order is identical and no pair can tie here that
  would not tie unsquared. Integers throughout.
* **No `break`/`continue`** — early exits use a guard flag with an explicit
  terminal assignment (`done`, `growing`); "continue" is a positive condition
  around the body.
* **No out-parameters or tuples** — `decode_pair` leaves its answer in module
  globals `dec_a`/`dec_b`, and `circuit_sizes` returns its count while leaving
  the sizes in `sz_buf`.
* **`split()` drops exactly one trailing empty field** — the parse counts commas
  in the bytes *and* checks the split length (see above).
* **`main()`'s return value is not the exit status** — the idiom is
  `def main() -> long { … }; exit(main())`, so every error path's `return 2` /
  `return 1` really is the process's exit status.
* **`>>` vs `>>>`** — the radix shifts use `>>` on keys that are never negative;
  `>>>` (logical) would be catastrophic on a negative, and none is used.
* **`[0; n]` needs a literal size**, so the buffers are written with literal
  sizes and the bounds are checked by hand at the parse (`more than 1024 boxes`
  is an error with its line number, not a trap).
* **Runtime traps print to stdout**, so no path can be allowed to trap: the
  parse refuses malformed input with a message, `solve` clamps a malformed
  order index instead of indexing out of bounds, and `--check` exercises every
  refusal path.

## Files

| file | what |
|---|---|
| `day08.y` | the whole program (the only source) |
| `input.txt` | this account's puzzle input, vendored — gitignored |
| `EXPECTED` | the deterministic output of `./day08` |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |
| `.gitignore` | keeps `input.txt` out of git |
| `day08` | the built binary (gitignored by the repo's rules) |

**Toolkit: none vendored.** This example needs no file from
`test/std/` and no std unit beyond `fs` — no `fx.y` (all arithmetic
is integer, no trig), no `tui` (no terminal drawing, nothing timed
in-process), no `args` (the four flags are a 30-line hand-rolled loop). Nothing is
edited and nothing is imported across folders; `day08.y` imports only `fs` from
the compiler's own std pack. The frozen toolkit's shas are therefore not
recorded here because no file from it is present.

Self-containment: the folder builds and passes with every other `examples/aoc`
day deleted — it imports nothing from a sibling day, and its only data file is
its own `input.txt` copy.
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
