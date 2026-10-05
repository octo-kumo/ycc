# AoC 2025, day 11 — "Reactor", in Y

A solver for [Advent of Code 2025 day 11](https://adventofcode.com/2025/day/11),
written in Y and built with the pinned compiler in `refs/ycc.ref`. It reads
the puzzle input, counts paths in a directed device graph, and prints **both**
answers plus the facts they are derived from.

```
day11: Advent of Code 2025 day 11 -- Reactor
input: input.txt
devices: 586 (585 device lines, 1665 connections)
topological order covered all 586 devices, so the graph is a DAG
part 1 (paths from you to out): 746
part 2 (paths from svr to out through both fft and dac): 370500293582760
  route svr -> fft -> dac -> out: 7394 * 13165590 * 3806 = 370500293582760
  route svr -> dac -> fft -> out: 1043301951635 * 0 * 4323428216726 = 0
all paths svr -> out, unfiltered: 342609490608038990
longest path you -> out: 8 devices
the 5 devices carrying the most paths from svr (out excluded):
  1. 35904172609296314  hsx
  2. 27933048758439358  rnx
  3. 27933048758439358  zzx
  4. 24533391760014534  sdm
  5. 24533391760014534  zrr
```

## Answers (real input, `input.txt`)

| part | question | answer |
|---|---|---|
| 1 | how many distinct directed paths lead from `you` to `out` | **746** |
| 2 | how many distinct directed paths lead from `svr` to `out` through **both** `fft` and `dac` | **370500293582760** |

Both were also computed by a throwaway Python solve written independently of
this program (a memoised `dfs(node, dst)` and the three-segment product), which
agrees on both numbers and on all six segment counts. Part 1 was additionally
confirmed by brute-force enumeration in Python: exactly 746 distinct paths, the
longest 8 devices long.

## Build and run

```sh
cd examples/aoc/day11
../../../refs/ycc.ref day11.y -o day11     # THREE .. -- see gate.conf
./day11                                    # both answers from input.txt
./day11 --check                            # the property battery
./day11 --help
./day11 --permute 1|2|3                    # solve a permutation of the input
./day11 input.txt                          # or any other input file
./inject.sh                                # defect injection table
```

Pinned compiler: `../../../refs/ycc.ref`, sha256
`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`.
Built binary: 66 359 bytes, sha256
`42a11322670776b4b32d1787fc9f5887dee5c6c1374a955561c7e4e5b384f994`.
Zero warnings. Every run is `ulimit -S -v 3670016` with `</dev/null`.

## The puzzle, in my own words

Below the factory floor is a large toroidal reactor, and next to it a new
server rack, with a tangle of cables and devices strung between them. The input
lists every device, one per line, as `name: n1 n2 n3 …`, meaning *the outputs
of `name` are attached to* `n1`, `n2`, `n3`, … Data flows from a device along
its outputs and never backwards. Four device names matter:

* **`you`** — the device next to the Elf who found the problem, and
* **`out`** — the reactor's main output,

for part 1; and for part 2

* **`svr`** — the server rack, and
* **`fft`**, **`dac`** — two devices whose names part 2 singles out.

**Part 1:** how many distinct directed paths lead from `you` to `out`? The
statement's example (ten lines) has **5**.

**Part 2** (login-gated; see *Where the answers come from*): how many distinct
directed paths lead from `svr` to `out` through both `fft` and `dac`?

Two facts about this data are worth stating because the solver leans on them
and the program *checks* rather than assumes them: the graph is acyclic (a
topological order covers all 586 devices), and every connection is one-way (no
edge has its reverse, which would be a 2-cycle). The graph is also small in
one direction and wide in the other: `svr` reaches all 586 devices, `you`
reaches 111 of them.

### What to look at

| file | what |
|---|---|
| `day11.y` | the whole program, 1465 lines with comments |
| `interner_add`, `parse_graph` | names → integer ids, and the CSR build |
| `count_paths` | the memoised pull DP (part 1's production method) |
| `push_counts` | the same recurrence run the other way (part 1's cross-check) |
| `enumerate_paths` | brute force: every path, materialised and checked |
| `part2_segments` | part 2 as the product of three segment counts |
| `walk_both` | part 2 as one walk carrying two "have I been here" flags |
| `msort` / `sort_pairs` | the merge sort, on two parallel arrays |
| `perm_lines` / `perm_rhs` / `perm_relabel` | the three permutations |
| `check_*` | the property battery |
| `inject.sh` | 24 injected defects, 23 caught (the one that was not is listed in full below) |
| `example.txt` | the statement's own worked example (part 1's anchor) |
| `example2.txt` | the write-up's worked example (part 2's anchor) |

## The shape of the problem, and what makes it hard

Counting paths in a DAG is a one-line recurrence — a device's value is the sum
of its outputs' values — and it is *not* where the care has to go. The care
goes in three places, and all three have already cost this program a wrong
answer (see *Three bugs that got past every method*, below):

1. **The graph must be the file's graph.** Names are opaque, so they are
   interned into integer ids by an open-addressed table, and the adjacency is
   built into CSR by a prefix sum. A degree counted per *line* instead of per
   *connection* is off by 1080 out of 1665 here and still produces a plausible
   DAG with plausible answers.
2. **A DAG has exponentially many paths** — 3.4 × 10^17 of them from `svr` to
   `out` — so nothing may enumerate them for part 2. Everything is memoised.
3. **Nothing may depend on the order of the input.** The dispatch note for this
   day was explicit that names are opaque identifiers, so the program never
   compares names and never uses a name's position, length or letters.

## The property check — `./day11 --check`

**113 assertions, all passing.** Its actual output is in the report below. It
runs in 9.8 ms. No reference file is involved: every expectation is published,
hand-worked in this README, or cross-checked by a second method.

Everything routes through `solve_graph(lines)`, the one entry point the binary
uses to print the answers, so a defect injected into the solver is injected
into the checks as well.

### 1. Anchors (tier 1 — external, published values)

* **Part 1: `5` on the statement's own worked example** (`example.txt`, the ten
  lines the statement prints). Published by the statement.
* **Part 2: `2` on a public write-up's worked example** (`example2.txt`).
  Baerentsen lists the paths of his example one at a time — exactly one
  `svr→fft` (`svr-aaa-fft`), exactly one `fft→dac` (`fft-ccc-eee-dac`), and
  exactly two `dac→out` (via `ggg`, via `hhh`) — and states the part 2 answer
  `2`. The multiplication principle turns his three counts into `1 × 1 × 2`,
  which is the number asserted. **The anchor is the traced segment counts, not
  just the total**: the check asserts `svr→fft == 1`, `fft→dac == 1`,
  `dac→out == 2` and `dac→fft == 0`, so a disagreement says *which* segment
  moved.
* **An edge case the statement's data cannot show**: `you` is absent from
  `example2.txt`, so its part 1 is 0 — a named device that is not in the graph
  is on no path at all. That path is exercised rather than assumed.
* **Part 2 on the statement's example is 0**, for the same reason (`svr` is not
  in it).

### 2. Hand-computed micro-cases, with the arithmetic

Every one of these goes through the real parser and all four counting methods.

| case | input | hand-worked | asserted |
|---|---|---|---|
| statement example | the ten lines above | 5 paths (the statement says so) | p1 5, p2 0 |
| two-device chain | `you: a` / `a: out` | `you→a→out`: **1** | 1 |
| one hop | `you: out` | `out` is a sink with no line of its own: **1** | 1 |
| fan out | `you: a b` / `a: out` / `b: out` | `a→out` and `b→out`: **2** | 2 |
| diamond | `you: a b` / `a: c` / `b: c` / `c: out` | `a→c→out` and `b→c→out` are two *different* paths: **2** | 2 |
| dead end | `you: a b` / `a: out` / `b: c` | `b` reaches nothing: **1** | 1 |
| out unreachable | `you: a` / `a: b` / `b: c` | nothing reaches `out`: **0** | 0 |
| you is a sink | `you: a` | no path leaves `you`: **0** | 0 |
| trailing space | `you: a b ` / `a: out` / `b: out ` | the trailing blanks are separators: **2** | 2 |
| double space | `you: a  b` / `a: out` / ` b: out` | the run of blanks is one separator: **2** | 2 |
| repeated output | `you: a a` / `a: out` | two cables to the same device are two paths: **2** | 2 |
| part 2, one chain | `svr: fft` / `fft: dac` / `dac: out` | `1×1×1`, and the other order has no paths: **1** | 1 |
| part 2, 1×2×2 | see below | `1×2×2`: **4** | 4 |
| part 2, out cut off | `svr: fft` / `fft: dac` / `dac: p` / `p: q` | `dac→out == 0`: **0** | 0 |
| part 2, svr cut off | `svr: p` / `p: out` / `fft: dac` / `dac: out` | nothing from `svr` reaches both: **0** | 0 |
| part 2, `dac` missing | `svr: fft` / `fft: out` | a device not in the graph is on no path: **0** | 0 |
| part 2, other order | `svr: dac` / `dac: p q` / `p: fft` / `q: fft` / `fft: out` | `1×2×1`: **2** | 2 |

The `1×2×2` case, spelled out, is the multiplication principle in miniature:

```
svr: fft          svr -> fft            1 path
fft: x y          fft -> x -> dac      ┐
x: dac                                 ├ 2 paths  (x or y)
y: dac             fft -> y -> dac      ┘
dac: p q          dac -> p -> out      ┐
p: out                                 ├ 2 paths  (p or q)
q: out            dac -> q -> out      ┘
```

Four paths in total, and each is a *different sequence of devices* even though
they all pass through the same three waypoints — which is the case a solver
that counted sets of devices instead of paths would get wrong.

The last row matters for a second reason: there, `dac` comes **before** `fft`.
A solver that only ever searched `svr→fft→dac→out` would get 0 and never know
it had looked the wrong way round.

### 3. Independent cross-checks — five methods, one quantity each

| quantity | method A (production) | method B (cross-check) | how B differs |
|---|---|---|---|
| part 1 | `count_paths` — memoised **pull** DP, iterative explicit stack | `push_counts` — **push** DP over a topological order (Kahn, FIFO queue) | opposite data flow through the same recurrence |
| part 1 | `count_paths` | `enumerate_paths` — **brute force**, every path materialised and keyed | no recurrence and no memo at all; exponential, affordable only because `you` is 8 hops from `out` |
| part 2 | `part2_segments` — the **product** of three independent segment counts | `part2_flags` — one walk carrying two "seen" flags | different state space (4 per device), nothing multiplied |
| the graph | `parse_graph`'s two tokenizers | the CSR is **re-derived from the file**, row for row | a second reader of the input, not a second run of the first |
| the order | the table's total order | permutation oracle (below) | varies the input's *order* rather than re-deriving the answer |

The enumeration is the oracle that differs in *kind*: it counts 746 by writing
each path down, while the DPs count 746 by arithmetic. It also checks its own
output — 0 duplicate paths (each is keyed by its device **names**, not its
ids), 0 attempts to step onto a device already on the path, and its longest
path (8 devices) must agree with `longest_path`'s topological answer.

Brute force is **impossible** for part 2 (3.7 × 10^14 paths), which is the
puzzle's point and the reason the cross-check there is the flag walk instead.

### 4. The permutation oracle

Three permutations of the input, each through `solve_graph` again, and
**the answers must not move**:

1. **`perm_lines`** — the device lines, back to front. Ids are handed out in
   first-seen order, so this alone renumbers the whole graph.
2. **`perm_rhs`** — every line's output list, back to front.
3. **`perm_relabel`** — every device **except the five the statement names**
   gets a new opaque name built from its id: `q353z`, `q0z`, … The names
   change, change length, and acquire digits, which the real ones never have.
   The five special ones (`you`, `out`, `svr`, `fft`, `dac`) keep their names
   because the puzzle *defines* them by name — renaming them would change the
   question, not the input. All three combined for permutation 3.

This is the check that varies the input's **order** rather than re-deriving the
answer the same way twice. It is here because of `day05`, whose worst bug was
the best argument for it: a sort that interleaved `(lo,hi)` into one array and
sorted the *values*, comparing one pair's high against another pair's low. It
compiled, it sorted, and **every part-2 method agreed with every other**,
reporting the same wrong answer. Only the permutation oracle noticed. Five
methods agreeing proves nothing if they are five readings of the same idea.

### 5. Invariants the answers must satisfy

* `part2 ≤ ` all `svr→out` paths — every qualifying path is one of the paths.
  Checked: 3.705 × 10^14 ≤ 3.426 × 10^17.
* `part2 > 0` requires all three segments of its route to be non-zero.
* **At most one order of `fft` and `dac` is reachable** (`fft→dac > 0` and
  `dac→fft > 0` together would be a cycle). Measured: 13 165 590 and 0.
* A path is at least two devices long, and `longest_path` agrees with the
  enumeration's maximum: 8.
* **No connection is mutual** — an edge with its reverse would be a 2-cycle,
  so this is an independent read on the acyclicity verdict. 0 of 1665.
* **The CSR is the file, row for row**: for each of the 585 lines, the source's
  CSR row must be exactly that line's outputs, in order, and the degrees must
  sum to the connection count.
* **The two tokenizers agree on every line.** `tokenize()` (byte level, runs of
  separators collapse) and the builtin `split(" ")` are counted per line and
  must match. `split()` drops exactly one trailing empty field and keeps the
  interior ones, so a line ending in a space or with two spaces in a row reads
  differently through it — which is why the parser does not trust either one
  alone.
* Presence guards before every comparison: 585 lines, 586 devices, 1665
  connections, all five named devices present, both answers > 0, 111 devices
  carry a path from `you`, 586 from `svr`. **A comparison of two values that
  are both absent passes**, so nothing is compared before it is shown present.

### 6. Guarding against a vacuous pass

* **The sort, three ways.** The order is asserted to be total and ascending
  (585 rows, 584 adjacent pairs); the result is asserted to be an **exact
  permutation** of the rows that went in (every device appears exactly once, no
  repeats, no names that are not devices); and every name is asserted to still
  carry **its own** count, looked up again by name. The last of those three is
  what a merge comparing one row's count against another row's name cannot
  pass. The sort works on **two parallel arrays** — `keys: [long]` and
  `names: [str]` — so that comparison is not even expressible; this is
  `day05`'s bug, designed out rather than tested for.
* **Canaries for the oracle.** A graph that differs in exactly one thing the
  oracle compares must be *noticed*: a repeated `fft` output on the `svr` line
  moves part 2 (370 500 293 582 760 → 370 550 401 818 300) and leaves part 1
  alone; a device nothing leads to adds one device and one connection and moves
  neither answer; dropping an output of `you` moves both. Injection 18 in
  `inject.sh` removes the part-2 comparison from `same_answers` and is caught
  by the first of these.
* **The comparison itself is unit-tested field by field** with hand-made
  records, because a graph canary can only move the fields the graph happens to
  be able to move — dropping a `you` output moves *both* answers, since `you`
  is itself reachable from `svr` in this input. Seven records, one field moved
  in each: all seven must compare different, and an identical pair must compare
  equal.
* **Defect injection**: `./inject.sh` runs 24 mutations and requires `--check`
  to fail on each. Result: **23 caught, 1 missed**.

#### The one injection that was not caught, and why

| # | mutation | why nothing noticed |
|---|---|---|
| 21 | `push_counts` expands `out` instead of stopping there | **`out` is a sink in this input** — it appears only as a target and has no line of its own — so it has no outputs and expanding it adds nothing. The change is real and the guard is load-bearing for an input where `out` has outputs, but *on this input* every method produces the same numbers with and without it. Listed rather than omitted. |

The other 23 include three that produced a **wrong answer** (injections 01,
03 and 19: 450, 4 and 1 respectively, where the truth is 746), two that tamper
with an *expectation* rather than the code (12, 13, 14 — the battery must
notice that the micro-case disagrees, not agree with the edit), and two that
weaken the *checkers themselves* (15, 18) to show those oracles are not
vacuous. Injection 22 is caught by a **runtime trap** rather than a `FAIL`
line, which `inject.sh` counts as caught and reports as such.

### 7. Error and argument paths (no trap on any of them)

Every one produces a message on **stderr** and exit **1** — no path can print a
runtime trap to stdout and corrupt `EXPECTED`:

| invocation | result |
|---|---|
| `./day11 missing.txt` | `cannot read missing.txt`, exit 1 |
| `./day11 /dev/null` | `no device lines`, exit 1 |
| a line with no `:` | `line 1: no ':' separator`, exit 1 |
| a line starting with `:` | `line 1: no device name before ':'`, exit 1 |
| `x: y` / `y: x` / `out: z` (cyclic) | `is not acyclic: a topological order covered 2 of 4 devices, so paths through it are not finite`, exit 1 |
| `./day11 --bogus` | `unknown option --bogus (try --help)`, exit 1 |
| `./day11 --input` (no name) | `--input needs a file name`, exit 1 |
| `./day11 --permute` (no number) | `--permute needs 1, 2 or 3`, exit 1 |
| `./day11 --permute 9` | `--permute takes 1, 2 or 3, not 9`, exit 1 |
| `./day11 a b` | `more than one input file given`, exit 1 |
| `./day11 --help` | usage, exit 0 |

The acyclic refusal is the interesting one: the input's DAG-ness is *checked*,
not assumed, and both counting methods that could run away on a cycle
(`count_paths` with its on-stack marker, `part2_flags` with an acyclicity gate,
because a state-carrying walk cannot detect a cycle itself) refuse rather than
spin.

## Three bugs that got past every method

Written down because they are the argument for the oracles above.

1. **The CSR counted degrees per line, not per connection.** One
   `start[s+1] += 1` per line instead of `+= len(outputs)`, so the last offset
   came out as the line count (585) rather than the connection count (1665).
   The graph was quietly not the file's. **Part 1 printed 450 and part 2
   printed 0** — the route multiplied out to 0 too, so the segment product and
   the flag walk *agreed with each other on a wrong answer*, and both were > 0
   nowhere. Only re-deriving the CSR from the file found it.
2. **The DFS frames were appended, not written at their depth.** `st += v`
   instead of `st[d] = v`: after the first pop, `len(st)` no longer equals the
   depth, so "the frame below me" was a stale entry and a finished value was
   added to the wrong parent. Part 1 went to **−2** on the statement's example.
3. **An already-resolved output contributed nothing.** The walk had a branch
   for `v == to`, a branch for `v` unresolved, and no branch for "already
   resolved" — so every path arriving through a device the walk had finished
   was dropped. Part 1 read **4** on the statement's example, where the answer
   is 5: the missing path was the second one through `ddd`.

Bugs 2 and 3 would have been caught by the push DP alone. Bug 1 by nothing
else in the program — it took a second reader of the input, which is now
`the CSR is the file, row for row`.

## Numbers

| | |
|---|---|
| build | 0 warnings from the pinned compiler |
| `./day11` | **1.6 ms** per run including process start (50 runs: 0.079 s) |
| `./day11 --check` | **9.8 ms** per run (20 runs: 0.195 s) — 113 assertions, eight full re-solves of the input (the baseline, three permutations, three canaries, plus the main pass) and 746 enumerated paths |
| binary | 66 359 bytes |
| peak RSS | **4 112 KB** default, 26 644 KB for `--check` |
| heap | **864 216 B** after `read_lines` + `parse_graph` (the 9 585-byte file as 585 strings, the 16 384-slot interner = 131 KB, and the CSR arrays grown by doubling); the whole solve after that — topological order, six memoised counts, two push passes, the longest-path pass, the flag walk and the sort — adds **771 672 B**, all of it the doubling growth of memo arrays allocated once per counting call |
| loop allocations | none in the default run. The only allocation inside a loop is the enumeration's per-path key string (746 of them, `--check` only); its array is hoisted out of the walk. `parse_graph`'s 12 string `cat`s and `perm_relabel`'s 6 are error paths and per-device renames, both exact-size copies |
| append audit | compiled with `-S` and counted per function: **one** `y_str_app` in the whole binary (`space_join`, the deliberate in-place amortised append) and 276 `y_str_cat` (value-used copies — their return values). No function has `cat` inside a loop, so there is no quadratic string building to find |

## Toolkit

**Nothing is vendored.** This example needs no `fx` (every number here is an
integer), no `term` (no terminal), no `fb` (no framebuffer), no `args` (three
flags are read from `argv()` directly) and no `time`. The frozen toolkit in
`examples/_toolkit/` is byte-identical and untouched; its shas, for the record,
are `fx.y 4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058`,
tui 07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee`,
tui 95a7663b7f1c7a90ff3756b51e51644ea952c9b671eeca1012b8f64e18589697`,
args cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28`,
tui 6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b`.

## Compiler workarounds

**No compiler bug was found for this day**; nothing is filed in
`examples/BUGS.md` or `examples/SUGGESTIONS.md` on its account. The traps below
are language facts, worked around in `day11.y` and visible there rather than
silent.

* **No `sort`.** `msort`/`sort_pairs` are written here, over two parallel
  arrays, ordered by count descending then name ascending (a total order, so the
  printed table is reproducible). The scratch pair is allocated once, in
  `sort_pairs`, and handed down — never inside the recursion.
* **`split()` drops exactly one trailing empty field** and keeps interior ones,
  so `"a b ".split(" ")` has 2 entries and `"a  b".split(" ")` has 3 (one of
  them empty). `tokenize()` is byte level instead, and the parser counts the two
  against each other per line rather than trusting either.
* **`s[i]` on a `str` is a `byte`, and `str + byte` SEGFAULTS** (brief §3), so
  the tokenizer cannot build names from bytes. It slices instead: `rest[lo:i]`
  with indices computed over the byte values, and compares separators with
  `(rest[i] & 255) <= 32`.
* **`chr()` cannot make a non-ASCII glyph** and there is no byte→`str`
  conversion, so the relabelling permutation builds names with
  `"q" + tostring(id) + "z"` — string + string — rather than by reversing bytes.
* **`main()`'s return value is not the exit status**, so the driver is
  `def main() -> long { … }; exit(main())` and error paths `return 1`.
* **Runtime traps print to stdout**, so every error path writes to `eputs`
  (stderr) and returns 1. `--check` counts a trap as a *caught* defect, never
  as a pass.
* **No `break`/`continue`**; early exit is a guard condition and the walks
  carry an explicit depth counter `d`.
* **`[0; n]` needs a literal size**, so every buffer is grown from a typed empty
  array (`while (i < n) { a += 0 }`) with `n` a variable.
* **A def is a first-class value** (`(parameter type) -> return type`), which is
  how the permutation helpers take their comparison argument; a plain `fn` with
  a `Res` parameter is used instead where the parameter list would be awkward.
* **There is no JSON, no `sort`, no `push`/`pop`.** `+=` and `*=` on arrays are
  the whole array interface; a queue is an array with a head index, which is
  what `topo_order` uses, and a stack is an array plus a depth counter.

## Where the answers come from

The statement page for day 11 is public and was read once. **Part 2 is
login-gated**: an unauthenticated `https://adventofcode.com/2025/day/11` returns
only part 1, one puzzle and a login prompt, so part 2's definition is not in the
statement and was not guessed.

Part 2 was taken from public write-ups, which agree on it:

* <https://blog.lojic.com/2025/12/12/advent-of-code-2025-day-11-reactor/> —
  "For part 2, we search for 3 successive segments, and multiply each of their
  totals together", over `svr-fft-dac-out` and `svr-dac-fft-out`, summed; it
  also gives the equivalent single walk carrying two flags.
* <https://scalacenter.github.io/scala-advent-of-code/2025/puzzles/day11/> —
  "counting only paths that pass through two particular nodes (in any order)",
  with the multiplication principle spelled out and the note that a DAG cannot
  have both `fft⇢dac` and `dac⇢fft`.
* <https://antoineprdhmm.github.io/competitive-programming/advent-of-code-2025-day-11-part-2-explained/>
  — the same two-flag walk, and an account of the exponential blow-up that
  makes it necessary.
* <https://baerentsen.space/aoc-2025-day-11/> — the **anchor**: a worked
  example with its paths listed and the answer **2**.

So part 2 asks for the number of directed `svr → out` paths that pass through
**both** `fft` and `dac`, in either order. The statement's text is paraphrased
above rather than copied.

### Which anchor tier, and the residual risk

**Tier 1 (external).** Part 1's anchor is the statement's own published answer
(`5`) on the statement's own example. Part 2's anchor is a public write-up's
published answer (`2`) on its own worked example, with the three segment counts
it traces (`1`, `1`, `2`) asserted individually — so the anchor is not merely
"a total some solver produced", it is three externally stated facts plus a
product.

Two honest caveats:

1. **The write-up's prose contradicts itself and the check follows the
   contradiction.** It says `svr → dac: 0`, but its own traced path
   `svr-aaa-fft-ccc-eee-dac` *is* one such path, and this program measures 1.
   So `svr→dac` is printed and **not asserted**. It changes nothing: the other
   route's product is 0 because `dac→fft == 0`, which is forced by acyclicity
   and *is* asserted. The anchor value (`2`) and the three traced counts are
   unaffected.
2. **`example2.txt` is my reconstruction, not his file.** It is the minimal
   graph that realises the counts he lists. I verified in Python that it has
   exactly `svr→fft = 1`, `fft→dac = 1`, `dac→out = 2`, `dac→fft = 0`, and it
   deliberately has no `you` at all, so his part-1 value for it is not claimed.
   A graph with additional edges consistent with his counts would give the same
   answer.

Residual risk on part 2's **interpretation**: low but not zero. Four
independent write-ups agree on the rule, the rule is the only sensible reading
of "two particular devices, in any order", and it is the reading that reproduces
the published example answer. What cannot be checked from outside is whether
the *real* input's answer is what the puzzle author intended — that is the
residual every AoC day carries, and the reason the interpretation is anchored
at all.

Residual risk on the **real-input answers**: none that I can see. Part 1 is
746 by four mutually independent routes (two DPs, an exhaustive enumeration,
and an independent Python solve). Part 2 is 370 500 293 582 760 by the product
of six segment counts, cross-checked by a flag-carrying walk, by containment in
the unfiltered total, and by an independent Python solve that agrees on all six
segments.

### Pin re-verification

The pin moves during the campaign. Re-read it at gate time: if `EXPECTED` stops
reproducing under a new pin, rebuild, re-run, and record the new sha — never
fake a match. At the time of writing, `refs/ycc.ref` is
`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`, and against
it: zero warnings, the deterministic run reproduces `EXPECTED` byte for byte
twice, no trap on any path, and `python3 ../../gate.py aoc/day11` reaches 9/9.

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
