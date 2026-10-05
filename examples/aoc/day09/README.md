# day09 — Advent of Code 2025, day 9: "Movie Theater"

A Y-language solution to AoC 2025 day 9, both parts, with a property battery
that does not trust its own golden file.

```
part 1 (largest rectangle, tiles): 4774877510   corners 83339,85864 and 13322,17670
part 2 (largest rectangle wholly inside the room, tiles): 1560475800   corners 5649,67626 and 94564,50077
```

## Build and run

```
cd examples/aoc/day09
../../../refs/ycc.ref day09.y -o day09     # THREE '..': day09 -> aoc -> examples -> root
./day09                                    # both answers, deterministic
./day09 --check                            # the property battery
./day09 --help
```

Built and verified against the pinned compiler
**`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**
(`refs/ycc.ref`). Zero warnings. The whole run is **0.009 s**; `--check` is
**0.100 s**.

The pin moved once while this example was being written (`6dcd7071…` →
`4a58dd5d…`). I rebuilt, re-ran the default run, `--check` and `inject.sh`
under the new pin: `EXPECTED` is byte-identical, 95/95 assertions still pass
and 37/44 defects are still caught. The sha above is the one the last
verification actually ran against.

`./day09` reads `input.txt` from the working directory. `--input FILE` solves
another tile list. There is no `--seed`: the real input is fixed, the default
run is deterministic, and nothing reads a clock, the terminal, or the network.

## What to look at

1. **`EXPECTED` is not the evidence — `--check` is.** `EXPECTED` proves
   determinism (byte-identical over repeated runs) and nothing else. The
   battery, run with `./day09 --check`, makes **95 assertions** and prints
   every one.
2. **The three independent oracles**, around `oracle_wall_filter`,
   `oracle_scan_prefix` and `shuffled`/`rotated`/`reversed`. The solver is an
   exact tile-complete predicate; oracles A and B compute the same quantity by
   a *different kind* of method, and oracle C varies the input's order
   instead of re-deriving the answer the same way twice.
3. **`inject.sh`** — 44 injected defects, 37 caught, and the 7 that were not
   are listed and explained rather than omitted. Run `./inject.sh`.
4. **The room's construction**, `build_band` and `rect_inside`: how a
   rectilinear polygon is turned into per-row accept intervals, and the
   union rule for vertex rows.

## The puzzle, in my own words

The theater floor is a big grid of square tiles and some tiles are red. The
input lists the red tiles, one `x,y` pair per line. Pick any two red tiles as
the **opposite corners** of an axis-aligned rectangle and make it as large as
you can.

The area is counted in **tiles**, not in spans: both corners are tiles, so the
rectangle from `(x1,y1)` to `(x2,y2)` is `(|dx|+1) x (|dy|+1)` tiles. The
statement's own worked example pins this down — `2,5` to `9,7` is 8 wide by 3
tall = 24, and `2,5` to `11,1` is 10 x 5 = 50.

* **Part 1:** using any two red tiles as opposite corners, what is the largest
  area of any rectangle you can make?
* **Part 2:** the red tiles, *in input order*, are the vertices of a closed
  axis-aligned polygon — the walls of the room. The same corner rule applies,
  but the rectangle must lie **wholly inside** the room: every tile it covers
  must be red (on a wall) or interior. **What is the largest area then?**

## Where part 2 came from, and how confident it is

**The statement page returns part 1 only.** Part 2's text is login-gated, so
the rule above was taken from public write-ups, and this section says exactly
which ones and how much the anchors constrain it.

Sources (each fetched once):

| source | what it gave |
|---|---|
| `stuart.mchattie.net/posts/2025/12/09/aoc-2025-python-day-09/` | part 2's rule in words: the corners, joined in order, form a rectilinear loop; a candidate rectangle must not have any **wall line** strictly inside it. Its code builds wall lines from **all pairs sharing an x or a y**. |
| `scalacenter.github.io/scala-advent-of-code/2025/puzzles/day09/` | the same rule as an intersection test: `allGreen(a) = !lines.exists(_.intersects(a.inner))`, where `lines` are the consecutive-tile edges made 1 tile wide, and `inner` drops one tile from each of the four sides. It also states plainly that its own check is *sufficient but not necessary* for the real input's shape. |
| `blog.lojic.com/2025/12/10/advent-of-code-2025-day-9-movie-theater/` | an independent formulation: walk the boundary, mark the tile just outside each edge, then require no marked tile in the rectangle. Also confirms the inclusive `(abs+1)` area. |
| `aoc.winslowjosiah.com/solutions/2025/day/9/` | the most careful write-up: three conditions — all four rectangle corners inside, no polygon edge inside, and the four corners of the rectangle *shrunk by one tile on all sides* also inside. It is explicit that this last condition exists because the two "no edge crosses" checks are not sufficient in general. |
| `aoc.just2good.co.uk/2025/9.html` | ray casting for inside-ness plus an edge/rectangle intersection check, and a clear statement of the failure mode (a rectangle whose centre is inside but which overlaps a "dent"). |

So the rule I implemented is **not one write-up's reading**: it is the
tile-exact version that the write-ups approximate, and the approximations
themselves are shipped as two of the oracles.

### The anchor tier: **tier 2 (self-derived) for part 2, tier 1 for part 1**

* **Part 1 is tier 1 (external).** The statement's own worked example, the
  eight tiles `7,1 / 11,1 / 11,7 / 9,7 / 9,5 / 2,5 / 2,3 / 7,3`, has the
  answer **50**, and the solver reproduces it exactly. The inclusive-area rule
  is externally confirmed too, since the statement also gives 24 for
  `2,5`–`9,7` and 35 for `7,1`–`11,7`, and `(9-2+1)*(7-5+1) = 24` and
  `(11-7+1)*(7-1+1) = 35` match.
* **Part 2 is tier 2 (self-derived), and I want to be plain about that.** I
  could not find a write-up that states part 2's answer **for the statement's
  example**, so the example's part-2 answer **24** is *my own* hand
  computation, made before the code existed and re-derived afterwards. It
  validates the **implementation**; it is **circular about the
  interpretation**. If I misread the rule, my code and my expected value would
  be wrong together and agree perfectly.
* **What partly offsets the circularity**, and is not an anchor but real
  evidence: the solver implements the *tile-exact* rule (every covered tile is
  interior or on a wall), whereas the published checks are approximations that
  their own authors flag as such. On both the example and the real input, the
  tile-exact answer equals the answer from **three different published
  approximations** (oracles A and B below, plus the Winslow three-condition
  test reproduced in Python). A misreading would have to be shared by the
  exact rule *and* by three independent approximations of it to survive.

**Residual risk, stated honestly.** The risk is not in the arithmetic — it is
in the possibility that the real AoC part 2 differs from "wholly inside the
loop" in some way none of the five write-ups mentions, e.g. counting
something other than tiles, or excluding rectangles that touch a wall. Every
write-up I read treats wall tiles as *inside* (Winslow's conditions 1 and 3
count on-boundary points as inside; stewSquared's `remove_poly_border` deletes
the polygon border from the "outside" set), and I followed that. If AoC's real
rule scores the part-1 rectangle instead, part 2 would be 4774877510; if it
demanded strict interiority, part 2 would be smaller. My answer comes from my
own solver on the real input either way, and the anchors only ever validated
the interpretation.

## The input

Vendored from `examples/aoc/inputs/day09.txt` (gitignored there) into
`input.txt`, with a folder-level `.gitignore` keeping it out of git. **496
lines.** Verified before writing any code, not assumed: an
`awk -F,` field count gives **496 lines each with exactly 2 fields**, and a
regex rejecting anything but `^[0-9-]+,[0-9-]+$` leaves **0** non-matching
lines.

What the input actually is, as the solver establishes it (all asserted in
`--check`):

* 496 tiles, **no duplicates**.
* **248 distinct x levels, each used by exactly two tiles**; likewise 248 y
  levels. That is the signature of a proper rectilinear room: every level
  carries exactly one wall segment.
* Every consecutive pair (including last → first) is axis-aligned, so the loop
  closes, and the shoelace sum is positive (CCW, simple).
* x spans `[1522, 98228]`, y spans `[1716, 98234]`. The room's area by
  shoelace/2 is **7 102 797 211** tiles; part 1 reaches 67 % of it and part 2
  22 %.
* Of the 122 760 tile-corner rectangles, **1807** are wholly inside the room,
  and the largest of them is part 2's answer.

Parsing is strict on purpose. `tonum` is *lenient* — it stops at the first
non-digit and ignores the rest — so every field is gated on a hand-written
`all_digits` (optional `-`, then one or more digits, nothing else) before it
is converted. A second, byte-at-a-time reader (`rescan_bytes`) that never
calls `split()` or `tonum()` re-reads the same file and must agree.

## The property battery

`./day09 --check` — **95 assertions, 0 failures**, no reference file
involved. Full output is at the end of this file.

### Hand-computed micro-cases

Each expected value is worked out here so a reader can check the arithmetic
without running anything.

**The statement's example** (8 tiles, the loop
`7,1 → 11,1 → 11,7 → 9,7 → 9,5 → 2,5 → 2,3 → 7,3`), expected **part 1 = 50**
(published), **part 2 = 24** (hand-derived):

* part 1: `2,5`–`11,1` gives `(|11-2|+1) x (|5-1|+1) = 10 x 5 = 50`. Nothing
  beats it; the next candidates are `7,1`–`11,7` = `5 x 7 = 35` and
  `2,5`–`9,7` = `8 x 3 = 24`.
* part 2, by hand. The room's rows, y from 1 to 7, and what each accepts:
  * y=1,2: interior x in `[8,10]` (walls at x=7 and x=11).
  * y=3,4: the wall at y=3 runs x=2..7 and the wall at x=7 runs y=1..3, so
    row 3 accepts x in `[3,6]` (interior) plus the wall tiles 2 and 7.
  * y=5,6: the wall at y=5 runs x=2..9 and x=9 runs y=5..7, so row 5 accepts
    interior x in `[3,8]` plus wall tiles 2 and 9; row 6 accepts interior
    x in `[8,10]` plus wall tiles 9 and 11.
  * The best legal rectangle is `2,5`–`9,7`... its y-range is 5..7 and row 6
    only accepts x in `[8,10] ∪ {9,11}`, which does not contain `[2,9]`, so
    that one is rejected. The winner is `2,3`–`9,5`: rows 3,4,5 accept x from
    2 through 9 (2 and 7 on row 3, 2 and 9 on row 5, interior between), and
    the rows in between are all interior. That is `8 x 3 = 24`.
  * Nothing larger fits: any rectangle reaching row 6 or 7 must start at
    x >= 8, capping its width at 4, and rows 1–2 cap the height the other way.

**Unit square** `0,0 / 4,0 / 4,4 / 0,4` → both **25**. Part 1: the two
diagonals give `5 x 5 = 25`. Part 2: the rectangle *is* the room, so 25 — the
case that proves a rectangle is allowed to coincide with the walls.

**L shape** `0,0 / 4,0 / 4,2 / 2,2 / 2,4 / 0,4` → part 1 **25**, part 2
**15**. This is the case part 2 exists for. Part 1: `4,0`–`0,4` spans the
room's bounding box, `5 x 5 = 25`, ignoring the notch. Part 2: rows 3 and 4
accept only x in `[1,2]` (3 tiles), so no 5-wide rectangle can include them;
the best is `0,0`–`4,2` (`5 x 3 = 15`) or `0,0`–`2,4` (`3 x 5 = 15`).

**Degenerate rectangles**, the tightest the inclusive rule gets:

* two identical tiles `5,5 / 5,5` → **1** (`1 x 1`);
* a one-tile list `3,3` → **0**: there is no pair, so no rectangle, and the
  program says so rather than trapping;
* two adjacent tiles `5,5 / 6,5` → **2** (`2 x 1`);
* a 1-tile-wide sliver `0,0 / 0,3` → **4** (`1 x 4`), the "thin rectangle"
  shape the statement's own example mentions.

**The reader's decision table.** `parse_rows` returns the index of the first
malformed row, or −1, and `rescan_bytes` returns a count of malformed bytes.
The battery pins both, including the case that made me correct an expectation
rather than the code: **`1,\n` is two violations, not one** — the second field
is empty *and* the line ends with an uncommitted field — so the count is 2.
Rejected: `12` (one field), `1,2,3`, `1,2x`, `1,`, `,2`, `a,b`, `-,2`,
`+1,2`. Accepted: `12,34`, blank rows (skipped), `  7 , 1  ` (trimmed, giving
exactly 7 and 1), `-3,4` (giving exactly −3).

### Oracles — each a different *kind* of computation

| oracle | method | why it is not the solver again |
|---|---|---|
| **A** `oracle_wall_filter` | reject a candidate if any wall line (a 1-tile-wide rectangle joining consecutive tiles) touches the candidate's **inner** area | stewSquared's intersection test. Edge-intersection geometry, not per-row accept intervals. |
| **B** `oracle_scan_prefix` | paint a (W−1)x(H−1) compressed grid inside/outside by **scanline fill**, then answer each candidate with one **2-D prefix-sum** query | a completely different algorithm shape: a filled grid and O(1) range queries. |
| **C** `shuffled` / `rotated` / `reversed` | 8 deterministic shuffles, 3 cyclic rotations, the reversal — all through the **real `solve_part1`/`solve_part2`** | **varies the input's order** instead of re-deriving the answer the same way twice. This is the check that exists because of `aoc/day05`, whose `sort_pairs` sorted the *values* of an interleaved `(lo,hi)` array, so it compared one pair's high against another pair's low: it compiled, it sorted, and every part-2 method still agreed with it. Only an oracle that permutes catches that class. |
| **D** `rescan_bytes` | a byte-at-a-time scan of the file that never uses `split()`/`tonum()` | a second, unrelated *reader*. A parser defect cannot hide behind itself. |
| **E** transposition / reflection / translation | part 1 under `x↔y`, under `x → −x`, and under `+100000,−20000` | the solver holds no absolute coordinate, and `(|dx|+1)(|dy|+1)` is symmetric and translation-invariant. |

Note on **C** and part 2: a free shuffle *destroys* the room (it is defined by
the tiles' cyclic order), so part 2's order-invariance is only rotations and
reversal. Each permutation is asserted to **actually reorder** the tiles — an
oracle that is secretly the identity cannot see an order bug, which is the
"two absent values compare equal" trap in permutation form.

Two more answers were obtained outside this program and are pinned, not merely
bounded: part 1's maximum is attained by **exactly 1** pair and part 2's by
**exactly 1** legal pair (an independent exhaustive enumeration). Pinning a
count matters because `ties1 == ties1` would pass no matter what. That
enumeration also counted the legal tile-corner rectangles at **1807**, and the
per-level widening described below was read off it.

### The room predicate, asked directly

A maximum answer only ever reveals the legality of **one** rectangle, so
`rect_ok` exposes the predicate and the battery asks it about named
rectangles on the real input. Widening the winning rectangle's right edge from
x=94564 in tile *levels*:

| levels | x | verdict |
|---|---|---|
| +0 | 94564 | inside (the winner) |
| +1 | 94720 | **still inside** |
| +2 | 94966 | **still inside** |
| +3 | 95034 | **still inside** |
| +4 | 95127 | **not inside** |

and upward from y=67626: +1 level (67767) inside, +2 (68943) not. Pinning
*which* level flips the verdict is a far sharper test than "some bigger
rectangle is rejected". Also pinned: the bounding box rejected; the bounding
box's **other** diagonal *accepted* (so the room is demonstrably not convex —
"the bounding box is rejected" alone would not have proved the predicate
discriminates); the 2x2 block on the first wall segment accepted; a rectangle
over the dent near the third tile rejected while the in-bounds 2x2 block beside
it is accepted; and the verdict unchanged when the two corners are named in the
opposite order.

`rect_ok` **refuses** a coordinate that is not a tile level rather than
rounding it to the nearest one — falling back would answer a question nobody
asked, which is the "two absent values compare equal" trap in geometric
costume (injection D41).

### Two hand expectations the check corrected, not the other way round

Worth recording, since the discipline is to treat a disagreeing check as right
until proved otherwise:

1. I asserted that widening the winning rectangle by **one** x tile level would
   be rejected. The check disagreed; on investigating, the check was right —
   there are **three** levels of slack at that edge, not one. The expectation
   was corrected, and the exact level where the verdict flips is now pinned.
2. I asserted that the rectangle between the 3rd and 5th tiles of the input was
   accepted. The check disagreed and the check was right: there is a dent right
   there. That first version also passed the corners in the wrong order
   (`xlo > xhi`), so it would have passed for the wrong reason; the predicate is
   documented as taking ordered corners and now is.

### Invariants

* part 2 ≤ part 1 (part 2's candidate set is a subset) — and here strictly
  below, since the room has a dent.
* part 1 ≤ (x span)(y span) = 9 334 062 933, the bounding box.
* part 2 ≤ the room's own shoelace area, 7 102 797 211.
* **Both** answers re-derived from the corners the program printed itself,
  `(|dx|+1)(|dy|+1)`, compared against the reported values.
* Both reported corners **occur in the input** — presence asserted before the
  comparison, so an absent value cannot make it pass.
* Each solver evaluates **exactly C(496,2) = 122 760** pairs, counted, so the
  candidate set is provably the whole set.
* The crossing count on every row slab is even and non-zero, which is what
  makes the loop a room at all; the top row's sentinels are checked too.
* **No allocation in either hot loop**, and no literal array or record inside
  any loop: `heap_used()` before and after each solver, both **+0 B** over
  122 760 iterations.

### Findings the battery and the degenerate-input probes produced

Three, none of which a golden file would ever have surfaced.

**An empty row slab is real, not hypothetical.** The real input has **one** row
slab holding no non-vertex row: the y levels 2985 and 2986 are exactly one
apart. So `rect_inside`'s guard for such slabs is a live code path. The
battery runs part 2 both with and without the guard and requires the same
answer (1 560 475 800), which shows the guard is non-binding *here* — see the
D15 row.

A second finding: `rect_inside` originally tested a vertex row for containment
in `[lo,hi]` **or** in the wall segment, and that is **wrong** — the acceptable
set is their **union**, and a rectangle can be legal only because the two
together cover it. It is fixed, and the union rule is now in the code and in
the comment. The fix did not move either answer, which is worth knowing: the
answer was right for a subtly wrong reason.

The third came from probing degenerate inputs by hand rather than from the
battery, which is its own lesson. The default run computed
`p1 * 100 / area2` unguarded, and a tile list with fewer than three vertices
encloses no area, so that is a **division by zero** — a runtime trap, which
prints to stdout and would corrupt `EXPECTED` instead of failing. The guard is
in place, and the battery now drives the reporting path on a one-tile list so
the path is covered (injection D44).

## Defect injection

`./inject.sh` — **44 defects injected, 37 caught, 7 not caught** (each of the
seven marked `nc` in the script and explained here; nothing is quietly
omitted). Each row replaces one exact string in a **scratch copy**, rebuilds
with the pinned compiler, and requires `--check` to fail. Replacement is
literal and must match exactly once, so a row cannot silently do nothing — a
row whose text is missing is reported as a *script* error, not as a detection.
And if the pinned compiler is not found (which is what happens if the folder is
copied outside the repo) the script **refuses to run** and exits 2, because
every row would otherwise be reported as a compile failure — 44 false
detections instead of none. Override with `YCC=/path/to/ycc` to run a copy
elsewhere; the count is identical there (37/7, verified).

Note D44: it is caught, but by the **trap** (the run dies with
`runtime error: division by zero` on stdout and a non-zero exit) rather than
by a failing assertion. That is a real trap on a real path — a one-tile list
encloses no area, so `p1 * 100 / area2` is `0/0` — and it is caught only
because the battery drives the default run's own reporting path on a
degenerate list. Traps print to stdout, so it would have corrupted `EXPECTED`
silently instead.

| # | defect | result |
|---|---|---|
| 1,2 | `(dx+1)` / `(dy+1)` loses its `+1` | caught (9, 9) |
| 3 | `\|dx\|` becomes a signed difference | caught (8) |
| 4 | pair loop starts at `i+2`, skipping the adjacent pair | caught (4) |
| 5 | maximum scan uses `>=` instead of `>` | **not caught** |
| 6 | tile *i*'s x read from its y slot | caught (11) |
| 7 | row interval's left end `>` becomes `>=` | caught (5) |
| 8 | row interval's right end off by one | caught (2) |
| 9 | wall at a vertex row no longer counts | caught (3) |
| 10 | condition B (vertex rows) not run at all | **not caught** |
| 11 | crossing interval collapses to its left end | caught (5) |
| 12 | half-open crossing `[lo,hi)` becomes `[lo,hi]` | caught |
| 13 | tile's compressed level looked up in the wrong array | caught |
| 14 | candidate loop's area filter dropped, so the **last** pair wins | caught (9) |
| 15 | `rect_inside`'s empty-slab guard dropped | **not caught** |
| 16 | loop no longer closed (last → first edge dropped) | caught |
| 17 | horizontal walls miss the closing last → first segment | **not caught** |
| 18 | strict digit gate removed, `tonum`'s leniency leaks through | caught (4) |
| 19 | a line with three fields is accepted | caught (1) |
| 20 | the y field is dropped, every tile lands on row 0 | caught (29) |
| 21 | x and y transposed while parsing | caught (7) |
| 22 | fields no longer trimmed | caught (1) |
| 23 | blank lines no longer skipped | caught (2) |
| 24 | a minus sign no longer accepted | caught (1) |
| 25 | insertion sort never moves anything | caught (1) |
| 26 | unique compaction drops the value, not the duplicate | caught (4) |
| 27 | insertion sort's condition reversed (descending) | caught |
| 28 | oracle A always says yes | caught (3) |
| 29 | oracle B's prefix sum counts inside cells | caught (2) |
| 30 | oracle C's shuffle is the identity | caught (1) |
| 31 | oracle C's rotation is the identity | caught (1) |
| 32 | oracle C's reversal is the identity | caught (1) |
| 33 | oracle D reads x into both fields | caught (2) |
| 34 | oracle D accepts any byte count | caught (2) |
| 35 | invariant `part2 <= part1` weakened to trivially true | **not caught** |
| 36 | tie count compared against itself (the `0 == 0` trap) | **not caught** |
| 37 | shoelace bound off by 2x | **not caught** |
| 38 | winning corner not looked for in the input | caught (1) |
| 39 | pair count compared against the wrong count | caught (1) |
| 40 | a wall segment filed under the wrong compressed row | caught (4) |
| 41 | `rect_ok` rounds a non-tile y level instead of refusing it | caught (8) |
| 42 | `rect_inside`'s union rule drops the exactly-touching case | **not caught** |
| 43 | `rect_inside`'s wall-alone branch of the union rule dropped | caught (1) |
| 44 | the shoelace divisor left unguarded, so a 0-area room divides by zero | caught (0 assertions; caught by the trap, see below) |

**The seven misses, honestly:**

* **D5** (`>` → `>=`) reports a *different one of the tied maxima*. The value
  is unchanged, and the answer is what the puzzle asks for. It is a
  presentation change, not a correctness one. (Note the battery pins *how many*
  pairs tie, not *which* one, precisely because which-one is a scan-order
  artefact.)
* **D10** (condition B skipped) does not bind on this input because condition
  A already covers every non-vertex row, and on this input every vertex row
  that a candidate reaches is also satisfied by A's interval. It is genuinely
  redundant **here**, not redundant in general — the L-shape micro-case and
  oracle A both exercise the vertex-row path, and D9 (weakening B rather than
  deleting it) *is* caught.
* **D15** (empty-slab guard dropped) cannot bind, for the same structural
  reason: the only empty slab (2985/2986) lies outside the winning rectangle's
  row range. The battery asserts the guard is present *and* that removing it
  changes nothing, which is the honest way to state a no-op guard.
* **D17** (closing horizontal wall dropped) is latent: `wall_rows` counts one
  wall per y level and the battery asserts that count is 0 duplicates, so a
  dropped wall shows up as a *missing* wall, which only matters if some
  candidate needs it. None does on this input. D40 — the same field written
  under the **wrong row** — **is** caught, which is the check that actually
  exercises that array.
* **D42** (`lo1 <= hi1 + 1` → `lo1 <= hi1 - 1` in the union rule) needs a
  vertex row where the wall segment **exactly abuts** the crossing interval —
  a one-tile gap that the merge has to bridge. No such configuration occurs
  in this input or in any micro-case, so removing that one case changes
  nothing. D43, which removes the *wall-alone* branch of the same rule
  entirely, **is** caught.
* **D35, D36, D37** are **strength** defects, not behaviour defects: they
  weaken an *assertion*, and a weakened assertion still passes a correct
  program, so no property battery can catch them by running. D36 is the exact
  `0 == 0` trap the standing briefing warns about; the fix for it is
  structural — every expected value must come from outside the code under test,
  which is why the tie counts are pinned to externally derived numbers and
  every micro-case is hand-worked in this file. I list them rather than omit
  them because a battery's coverage of its own assertions is exactly the thing
  a reader should not have to take on faith.

## Compiler workarounds

**No compiler bug was found.** Nothing is filed in `examples/BUGS.md` or
`examples/SUGGESTIONS.md` for this day. The obstacles below are language facts,
each worked around visibly in `day09.y` rather than silently:

* **`tonum` is lenient.** `tonum("12ab")` is 12 — the scan stops at the first
  non-digit and the rest is ignored. A parser built on it would accept
  malformed rows. Hence `all_digits` gates every field, and
  `+1,2` is rejected (the statement uses no plus sign).
* **No `sort`.** `isort` is a hand-written insertion sort over a slice, and
  `sort_unique` sorts then compacts runs. On 248 distinct levels that is
  ~30 k comparisons against 122 760 pair evaluations, so it is not the
  bottleneck; the hand-rolled sort is itself injection-tested (D25, D26, D27).
* **`[0; n]` needs an integer *literal* size**, so `zeros_long` / `zeros_byte`
  grow an array by `+= 0` instead.
* **No `break` / `continue`** (both are undefined names). Skipping is a
  positive condition wrapping the body; early exit is an explicit `return`.
* **`return` does not widen to an option type.** `return 0` from a `-> long?`
  function is an error, which is why the parse helpers return an index (`-1`
  for "no bad row") rather than `long?`.
* **`split()` drops exactly one trailing empty field**, so a file ending in
  `\n` does not produce a spurious empty row — but blank rows are skipped
  explicitly anyway, and `parse_rows` is tested on them.
* **A `let` inside a block does not escape it** (no hoisting), so the
  counters and the band arrays are declared at the top of their scope; the
  compile error `undefined variable` is how you find out.
* **`main()`'s return value is not the exit status**, so the driver is
  `exit(main())`.
* **A runtime trap prints to stdout**, which would silently corrupt
  `EXPECTED`. Every error and argument path here writes to **stderr** via
  `eputs` and exits non-zero; `--check` verifies no trap on any of them. I
  found one real trap by probing degenerate inputs — see "One finding the
  battery produced" above.
* **Quadratic-string audit.** Compiling with `-S` and counting
  `call y_str_app` (in-place, amortised) against `call y_str_cat` (exact copy)
  per function: **`solve_part1`, `solve_part2`, `rect_inside`, `count_ties`,
  `no_wall_inside`, `oracle_scan_prefix`, `isort`, `sort_unique`, `idx_of`,
  `zeros_long`, `absl` and `rescan_bytes` emit zero of both** — the hot paths
  build no strings at all. `cat` appears only in the error paths of
  `build_band`, `parse_text`, `parse_pair`, `rescan` and `rect_ok`, and in the
  reporting of `report`/`main`/`run_check`; none of them is inside a loop over
  pairs. There is no `str +=` anywhere in the file.

## The frozen toolkit

**Nothing is vendored.** This example needs no `fx` (every quantity is an
integer — there are no floats, no division except exact integer division of the
shoelace sum), no `term`, no `fb`, no `args` (four flags are read from
`argv()` directly) and no `time`. The frozen toolkit in `examples/_toolkit/`
is byte-identical and untouched; its shas, for the record, are
`fx.y 4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058`,
`term.y 07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee`,
`fb.y 95a7663b7f1c7a90ff3756b51e51644ea952c9b671eeca1012b8f64e18589697`,
`args.y cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28`,
`time.y 6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b`.

## Files

| file | what |
|---|---|
| `day09.y` | the whole program: parser, room construction, both solvers, the oracles, and the battery |
| `input.txt` | the vendored 496-line input (gitignored) |
| `EXPECTED` | the default run's stdout, byte-identical over repeated runs |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |
| `inject.sh` | 40 injected defects, 33 caught, 7 explained |
| `.gitignore` | keeps `input.txt` out of git |
| `README.md` | this file |

## Full `--check` output

```
day09: property battery -- no reference file is involved here
input: input.txt

shape of the input:
  tiles 496, x levels 248, y levels 248, max tiles on one x level 2, on one y level 2
  x in [1522, 98228], y in [1716, 98234]
  [ok]   every line had exactly two integer fields = 496
  [ok]   x levels = 248
  [ok]   y levels = 248
  [ok]   each x level is used by exactly two vertices = 2
  [ok]   each y level is used by exactly two vertices = 2
  [ok]   no duplicate tiles = 0
  [ok]   every consecutive pair is an axis-aligned edge = 0
  [ok]   the loop is simple (CCW shoelace is positive) = 1
  [ok]   oracle D: byte-level rescan agrees with the parser (496 tiles)

solver on input.txt:
  [ok]   part 1 evaluated exactly C(n,2) pairs = 122760
  [ok]   part 2 evaluated exactly C(n,2) pairs = 122760
  part 1 = 4774877510   pair 83339,85864 and 13322,17670
  part 2 = 1560475800   pair 5649,67626 and 94564,50077
  [ok]   y levels carrying two wall segments = 0
  [ok]   row slabs holding no non-vertex row = 1
  [ok]   part 2 is the same with rect_inside's empty-slab guard dropped = 1560475800
  [ok]   part 1's maximum is attained by exactly this many pairs = 1
  [ok]   part 2's maximum is attained by exactly this many legal pairs = 1
  heap across part 1: +0 B; across part 2: +0 B
  [ok]   part 1 allocates nothing in its 122 760-iteration loop
  [ok]   part 2 allocates nothing while scanning the pairs

the default run's reporting path on a degenerate list (no trap):
tiles: 1 (red tile coordinates)
room: a closed axis-aligned polygon through the tiles, 1 x-levels and 1 y-levels, each used twice
part 1 (largest rectangle, tiles): 0   corners 3,3 and 3,3
part 2 (largest rectangle wholly inside the room, tiles): 0   corners 3,3 and 3,3
answers: 0 0
  [ok]   a one-tile list reports 0 and 0 without trapping = 0

the room predicate, asked about specific rectangles:
  [ok]   the real input's winning rectangle is inside the room
  [ok]   right + 1 level (94720) is still inside
  [ok]   right + 2 levels (94966) is still inside
  [ok]   right + 3 levels (95034) is still inside
  [ok]   right + 4 levels (95127) is NOT inside
  [ok]   up + 1 level (67767) is still inside
  [ok]   up + 2 levels (68943) is NOT inside
  [ok]   the bounding box is NOT inside the room
  [ok]   the room's bounding diagonal is rejected
  [ok]   the other bounding diagonal is inside (this room is not convex)
  [ok]   the 2x2 block on the first wall segment is inside
  [ok]   a rectangle over the dent near tile 3 is rejected
  [ok]   the 2x2 block inside that same corner is inside
  [ok]   full width over the lower half is NOT inside
  [ok]   the predicate does not depend on which corner is named first

micro-cases (the arithmetic is written out in README.md):
  [ok]   statement example part 1 (published: 50) = 50
  [ok]   statement example part 2 (hand-derived: 24) = 24
  [ok]   unit square part 1 (5x5) = 25
  [ok]   unit square part 2 (the room itself) = 25
  [ok]   L shape part 1 (4,0 & 0,4 reach over the dent) = 25
  [ok]   L shape part 2 (longest legal run is 5x3 or 3x5) = 15
  [ok]   two identical tiles span 1x1 = 1
  [ok]   a one-tile list has no pair, so part 1 is 0 (and does not trap) = 0
  [ok]   two adjacent tiles span 2x1 = 2
  [ok]   two tiles sharing an x span 1 wide by 4 tall = 4
  [ok]   L shape: 5 wide x 5 tall is illegal, so part 2 < part 1 = 1

parser and reader decisions (what must be accepted, what must not):
  [ok]   a well-formed row is accepted = -1
  [ok]   one field ('12') is rejected = 0
  [ok]   three fields ('1,2,3') is rejected = 0
  [ok]   trailing junk ('1,2x') is rejected = 0
  [ok]   an empty second field ('1,') is rejected = 0
  [ok]   an empty first field (',2') is rejected = 0
  [ok]   letters ('a,b') are rejected = 0
  [ok]   a bare sign ('-,2') is rejected = 0
  [ok]   blank rows are skipped, not rejected = -1
  [ok]   the blank-row case read exactly two tiles = 4
  [ok]   whitespace around the fields is tolerated = -1
  [ok]   ...and the trimmed values are 7 and 1 = 7001
  [ok]   a negative field is accepted = -1
  [ok]   ...and it really is -3 = -3
  [ok]   the index of the first bad row is reported = 2
  [ok]   a plus sign ('+1,2') is rejected, since the statement does not use one = 0
  [ok]   rescan accepts '1,2\n' = 0
  [ok]   rescan read exactly the tile 1,2 = 1002
  [ok]   rescan rejects three fields = 1
  [ok]   rescan rejects a stream not ending on a line boundary = 1
  [ok]   rescan rejects a stray byte = 1
  [ok]   rescan rejects '1,\n' as two violations, not one = 2
  [ok]   rescan rejects a bare newline (one line, no fields at all) = 1
  [ok]   rescan reads a whole well-formed file in one pass = 0

oracles (each a different kind of computation from the solver):
  [ok]   oracle A: published no-wall-inside rule, real input = 1560475800
  [ok]   oracle A: published no-wall-inside rule, statement example = 24
  [ok]   oracle A: published no-wall-inside rule, L shape = 15
  [ok]   oracle B: scanline fill + prefix sums, real input = 1560475800
  [ok]   oracle B: scanline fill + prefix sums, statement example = 24
  [ok]   oracle B: scanline fill + prefix sums, L shape = 15
  [ok]   oracle C: 8 deterministic shuffles leave part 1 unchanged
  [ok]   oracle C: the shuffle really reorders the tiles (not the identity)
  [ok]   oracle C: the rotation really reorders the tiles
  [ok]   oracle C: the reversal really reorders the tiles
  [ok]   oracle C: 3 cyclic rotations leave BOTH answers unchanged
  [ok]   oracle C: reversing the loop order leaves BOTH answers unchanged
  [ok]   oracle E: part 1 under transposition (x<->y) = 4774877510
  [ok]   oracle E: part 1 under x reflection = 4774877510
  [ok]   oracle E: part 1 under translation by (+100000,-20000) = 4774877510

invariants:
  [ok]   part 2 <= part 1 (part 2's candidate set is a subset)
  [ok]   part 1 <= (x span)*(y span) of the bounding box 4774877510 <= 9334062933
  [ok]   part 2 <= the room's own area (shoelace/2) 1560475800 <= 7102797211
  [ok]   part 2 is strictly below part 1 (the room has a dent)
  [ok]   part 1 re-derived from its own reported corners = 4774877510
  [ok]   part 2 re-derived from its own reported corners = 1560475800
  [ok]   part 2 corner A occurs in the input = 1
  [ok]   part 2 corner B occurs in the input = 1
  [ok]   part 2 spans at least two rows and two columns
  [ok]   tiles used as loop vertices = 496
  [ok]   build_band validated the crossing count on every row slab

checks passed: 95   failed: 0
```

## Cross-checked outside this program

Both answers were also computed by a **throwaway Python solve written
independently** in a temp directory (never in this folder, and it does not
appear in the build), using the published no-wall-inside rule, a Winslow
three-condition test, and a scanline-plus-prefix-sum version of the exact
predicate. All three agree with the Y program on the real input
(`4774877510` / `1560475800`) and on the statement's example (`50` / `24`).
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
