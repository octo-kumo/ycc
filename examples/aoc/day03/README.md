# day03 — Advent of Code 2025, day 3 ("Lobby"), in Y

One self-contained folder: the puzzle solver, its property check, and the
puzzle input it reads. Nothing is imported from a sibling day; the folder
builds and passes with every other `examples/aoc/day*` deleted.

```
day03.y       the solver and the property battery (1113 lines)
input.txt     the vendored puzzle input: 200 banks of 100 digits (gitignored)
example.txt   the statement's own worked example: 4 banks of 15 digits
EXPECTED      the golden stdout of `./day03`
gate.conf     build= / run= / check= for examples/gate.py
inject.sh     defect injection: 19 mutants, and the check must fail on each
```

## Build and run

```sh
cd examples/aoc/day03
../../../refs/ycc.ref day03.y -o day03      # three .. : day03 -> aoc -> examples -> root
./day03 </dev/null                          # both answers from input.txt
./day03 --check </dev/null                  # the property battery (128 checks)
./day03 example.txt </dev/null              # the statement's example: 357 / 3121910778619
./day03 --bench </dev/null                  # timing + heap_used() (reads the clock)
./day03 --help </dev/null
./inject.sh                                 # 19 injected defects; 19 detected
```

Pinned compiler: `refs/ycc.ref`, sha256
**`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`**.
Built `day03` sha256 **`068e666a1ee5513ee37da8211c7b8ca71c50fdd9c3cc852d9dcad8bb4bb37e75`**
(source `day03.y` sha256 `840de92036b5ae0544a6583b2f28207a90213cf7c679196cf5fe5ee273a38ee9`).
`input.txt` sha256 `8ee162e2ec045ae807d0ae1280b0452c0257ce01b38bd8f7b9b8bb779dbe2a69`.

The pin moves during the campaign. If `EXPECTED` ever stops reproducing under a
new pin, rebuild, re-run and re-record the sha — never edit `EXPECTED` to fit.

## The answers

| | value |
|---|---|
| **part 1** (2 batteries per bank) | **17383** |
| **part 2** (12 batteries per bank) | **172601598658203** |

Both were then confirmed by a throwaway Python solve written independently of
this program, using two different algorithms *and* an exhaustive enumeration:
all C(100,2) = 4950 pairs per bank for part 1 gives 17383, and a
window-scan greedy and a monotonic-stack greedy both give 172601598658203 for
part 2. Per-bank part-1 joltage ranges 44..99, which the Python pair
enumeration reproduces exactly.

## The puzzle, in my own words

The elevators are dead; you need batteries for the escalator. Each line of the
input is a **bank** of batteries, each labelled with a **joltage rating** from
1 to 9. From a bank you turn on exactly *k* of them **keeping their original
order** — *"You cannot rearrange batteries"* — and the bank then produces the
number spelled by those *k* digits. Every bank contributes the largest such
number it can produce, and the answer is the sum over banks.

- **part 1** — *k = 2*: for each bank, the largest two-digit joltage; sum them.
- **part 2** — *k = 12*: the same, twelve batteries per bank.

The real input is 200 banks of exactly 100 digits, ratings 1..9, no zeros, no
blank lines — verified by `wc -l` and `awk '{print length}' | sort -u` from the
shell, and re-verified inside `--check` by a second, independent parse.

## Part 2 came from a write-up, not from AoC — here is exactly how confident it is

**Part 2 of every 2025 puzzle is login-gated.** The statement page was fetched
once, unauthenticated, and returned part 1 only (one `<h2>`, one puzzle, then a
login prompt) — so **part 2's wording was never read from AoC**. It is not in
this repository either; it is paraphrased above from public write-ups.

Primary source for part 2's definition:

- **Sean D. Stuber, "Advent of Code 2025 – Day 3"** —
  <https://seanstuber.com/2025/12/06/advent-of-code-2025-day-3/>
  > "I was kind of disappointed in day 3 because it's the same puzzle twice.
  > So one solution solves both parts 1 and 2, just changing the length from 2
  > to 12."
  He also works the second example bank by hand: *"With that 12-digit joltage
  though, I need to use ten of the 1s and then finish with the 9"* — i.e.
  `811111111111119`, which this program reproduces.

Corroborating sources (all agree on *k = 12*):

- Mark Weste, StyleInCode, "Day 3 – Advent of Code 2025" —
  <https://www.styleincode.fun/posts/advent-of-code/2025/day-03-advent-of-code-2025/>
  (`size = 12`, docstring *"largest twelve digit number"*).
  Its solution directory <https://code.styleincode.fun/advent_of_code/2025/03/>
  holds the statement's own example file.
- r/adventofcode's day-3 megathread, top-voted reply —
  <https://www.reddit.com/r/adventofcode/comments/1pcvaj4/2025_day_3_solutions/> —
  `sum(maxj(s, 2) for s in data)` / `sum(maxj(s, 12) for s in data)`.

### The two anchors

The check asserts the statement's own example **and** the write-up's, so a
misreading of part 2 cannot survive:

| anchor | value | where it comes from |
|---|---|---|
| part 1, statement's 4 banks, *k*=2 | **357** | the puzzle statement, authoritatively |
| part 2, the same 4 banks, *k*=12 | **3121910778619** | the write-up's own test constant |

`./day03 example.txt` prints exactly those two numbers, and `--check`
(section `[1]`) asserts every per-bank value behind them. The part-2 anchor was
**also derived by hand here**, independently, and agrees — the arithmetic is in
the next section. So the interpretation rests on three legs that do not depend
on each other: the write-up says *k*=12, the write-up's number for the example
matches what *k*=12 gives, and *k*=12 is the only reading consistent with the
statement's own part-1 anchor.

**If you only trust one thing here:** part 1 is from AoC and is solid. Part 2 is
a write-up's reading, corroborated by two further independent write-ups and
anchored on an example value that also falls out of a hand calculation.

## How the solver works

One engine answers both parts; only *k* changes. Four independent
implementations exist, and `--check` holds them against each other and against
an exhaustive brute force:

| engine | cost | method |
|---|---|---|
| `max_k_greedy` | O(n) | monotonic stack: keep the digits chosen so far, and while discards remain, drop a trailing digit the current one beats. What survives is non-increasing, so the leftover discards come off the tail. This is what the default run uses. |
| `max_k_window` | O(n·k) | fill the joltage most-significant digit first; for each position take the largest digit in the window that still leaves *t*-1 batteries behind, preferring the leftmost. The write-ups' algorithm. |
| `max_k_dp` | O(n·k) | `best(i,j) = max(d[i]*10^(j-1) + best(i+1,j-1), best(i+1,j))` over two rolling rows. No cleverness at all — that is the point. |
| `brute` | O(C(n,k)·k) | every k-subset, spelled out. Only usable on short banks. |

The banks are parsed once into one flat digit array with a start offset per
bank, so no bank is ever copied to be solved.

### What to look at

- `max_k_greedy` — the whole answer is twenty lines and there is no sort, no
  hash and no recursion in the default path.
- `IMPOSSIBLE` in `max_k_dp` — see "The DP bug the check caught" below.
- `check_exhaustive` / `exhaustive` — the proof, not a sample.
- `check_real` — the three-way cross-check and the invariants on the answers.
- `check_sort` — Y has no `sort`, so `sort_desc` is mine and gets asserted on.
- `solve` — the error paths. Every refusal is a message on stderr and exit 1.

## The property check (`./day03 --check`)

A golden file proves determinism, not rightness, and an AoC answer is a single
integer that a wrong algorithm reproduces perfectly. So the battery asserts
things instead. **128 checks, all passing; no reference file is involved.**
Every expectation is one of: worked out by hand below, published by the
statement, published by the part-2 write-up, or produced by a second method.

### [1] The two anchors

Asserted per bank *and* in total, for *k*=2 and *k*=12, plus all four engines
agreeing for every *k* from 1 to 12 on all four banks. `./day03 example.txt`
prints 357 and 3121910778619.

### [2] Hand-computed micro-cases

The rule, used throughout: keeping *k* digits from *n*, the *j*-th kept
position must be at or before column *n − (k − j)*, or the remaining digits
will not fit. At each position take the largest digit available up to that
limit; on a tie take the leftmost (it leaves the most room).

| bank | *k* | derivation | answer |
|---|---|---|---|
| `19` | 2 | j=1 ≤ col 1 → `1`; j=2 → `9`. **19, not 91** — this is the statement's *"you cannot rearrange batteries"* | 19 |
| `91` | 2 | j=1 ≤ col 1 → `9`; j=2 → `1` | 91 |
| `12345` | 2 | j=1 ≤ col 4 → largest of 1,2,3,4 is `4` at col 4; j=2 → `5`. (Only the last 4 can be the tens digit.) | 45 |
| `123456789` | 2 | j=1 ≤ col 8 → `8`; j=2 → `9` | 89 |
| `987654321` | 2 | j=1 ≤ col 8 → `9` at col 1; j=2 → `8` at col 2 | 98 |
| `55555` | 2 | every choice is 55 | 55 |
| `1` / `9` / `123456789` | 1 | the largest single battery | 1 / 9 / 9 |
| `987654321` | 9 | *k* = *n*, so the whole bank | 987654321 |
| `999999999999` | 12 | *k* = *n* | 999999999999 |
| `111111111111111` | 12 | fifteen ones, drop three from the tail | 111111111111 |
| `999999999999999` | 12 | fifteen nines, drop three | 999999999999 |
| `819191911111111` | 12 | j=1 ≤ col 4 → `9` at col 3 (**not** the leading 8, which would strand 14 batteries); j=2 ≤ col 5 → `9` at col 5; then all of cols 6..15 = `1 9 1 1 1 1 1 1 1 1` | 991911111111 |
| `11111111111` | 12 | only 11 batteries: refused, sentinel −1 | −1 |

The four anchor banks at *k*=12, which is the write-up's number re-derived by
hand (15 digits, keep 12):

| bank | derivation | 12-digit joltage |
|---|---|---|
| `987654321111111` | already non-increasing, so nothing is popped; the 3 discards come off the tail | 987654321111 |
| `811111111111119` | j=1 ≤ col 4 → `8`; j=2..11 ≤ cols 2..14 → ten `1`s; j=12 → col 15 → `9` | 811111111119 |
| `234234234234278` | the `8` and `7` are too far right to lead, so j=1 ≤ col 4 → `4` at col 3; j=2 ≤ col 5 → `3` at col 5; then all of cols 6..15 | 434234234278 |
| `818181911112111` | j=1 ≤ col 4 → `8` col 1; j=2 ≤ col 5 → `8` col 3; j=3 ≤ col 6 → `8` col 5; j=4 ≤ col 7 → `9` col 7; then all of cols 8..15 | 888911112111 |

```
  987654321111
+ 811111111119  =  1 798 765 432 230
+ 434234234278  =  2 232 999 666 508
+ 888911112111  =  3 121 910 778 619      <- the write-up's anchor
```

### [3] The statement's edge cases are refusals, not answers

A bank with fewer than *k* batteries has no *k*-digit joltage, so it must be
**reported, never trapped on**: `"12"` and `"987654321"` at *k*=12, an empty
bank, a non-digit, a rating below 1, *k*=0, and a bank one digit past the
1024-digit buffer cap. Also asserted: exactly *k* batteries is accepted, a
20-digit bank is accepted, a 1024-digit bank is accepted.

### [4] Exhaustive proof over the whole small state space

Not sampled. Every string over the alphabet `{1,2,5,9}` of length 1..6 is
enumerated, prefix by prefix, and for each of them every *k* from 1 to its
length is computed by **all four engines**:

- banks: `4+16+64+256+1024+4096` = **5460**
- (bank, *k*) pairs: `Σ L·4^L` = `4+32+192+1024+5120+24576` = **30948**
- brute-force leaf enumerations behind it: `Σ 4^L(2^L − 1)` = **294132**

Asserted: pairs enumerated = 30948 (so a truncated sweep fails rather than
passing quietly); engine-vs-brute agreements = 3 × 30948; **disagreements = 0**;
all 30948 answers are in-order subsequences of their bank; all 30948
strictly-increasing-in-k steps hold; all 5460 banks satisfy *V(n)* = the whole
bank.

### [5] The hand-written sort

Y has no `sort`. `sort_desc` is an insertion sort, descending, stable, sorting
in place with no allocation. It is asserted on, not just used:

- **Fixture A** `[5,5,3,9,1,9,0,7,5,2]` with bank numbers `[0..9]` must become
  values `[9,9,7,5,5,5,3,2,1,0]` carried to banks `[3,5,7,0,1,8,2,9,4,6]` —
  descending, and ties in bank order. Its shift count must be **17**: insertion
  sort shifts an element once for every *smaller* element ahead of it, and the
  per-`i` counts are 3+3+4+0+4+0+3+0+0 = 17.
- **Fixture B**: 200 values `(i·37) mod 23` — total preserved, non-increasing,
  stable, and a full 32-bucket histogram comparison proving every value kept its
  multiplicity (a sort that duplicated or dropped a value would fail).

### [6] The real input: three engines and invariants on the answers

- **Structural facts from outside the code under test.** 200 banks, all exactly
  100 digits, 20000 batteries — these constants come from `wc -l` and
  `awk '{print length}' | sort -u` run in a shell, not from this program. The
  line parse is then cross-checked against an **independent byte-level rescan**
  of the same file (`fs.read_bytes`, counting digit runs), and both counts are
  demanded non-zero.
- **Every bank is a run of ratings 1..9** — the statement's guarantee, checked.
- **Three engines, 2400 (bank, *k*) pairs** (*k* = 1..12 over 200 banks):
  greedy, window scan and DP must agree; every answer must be a real in-order
  subsequence of its bank; *V(k)* must rise strictly with *k*; appending one
  battery must never lower *V(k)*; and the append test must have run on every
  pair (never silently skipped).
- **The two totals, computed three independent ways**, each demanded
  non-zero *before* anything is compared with it:
  `part 1 = 17383`, `part 2 = 172601598658203`, and greedy == window scan ==
  DP for both.
- **Invariants on the answers.** Each bank contributes a *k*-digit number, so
  `nbank·10^(k−1) ≤ total ≤ nbank·(10^k − 1)`: part 1 pinned to
  `[2000, 19800]` and part 2 to `[2·10^13, 2·10^14 − 200]`. Part 2 must exceed
  part 1 (more batteries ⇒ a strictly larger number per bank). All 200 banks
  are bucketed by their leading digit to prove each part-2 joltage really has
  12 digits.
- **The printed ranking** is sorted and then checked against a plain
  linear-scan maximum, for order, and for stability.

### Guarding against a vacuous pass

Two agents in this campaign shipped checks that compared two **absent** values
and passed. Every defence here is deliberate:

- **Every observed value is demanded present and non-zero before it is
  compared.** Both totals are asserted `> 0` before they are compared with the
  other engines; both bank counts are asserted `> 0`; the exhaustive sweep's
  value total is asserted `> 0`, and its extremes are asserted to be exactly
  999999 (from the bank `999999` at *k*=6) and 1 (from `1` at *k*=1) — a sweep
  that returned a constant 0 could not produce that range.
- **Expected counts come from outside the code under test.** 200 banks and 100
  digits were counted by the shell and hard-coded; the byte rescan is a second,
  separate parse; the sub-sequence invariant is checked against the bank's own
  digits, not against another engine's answer.
- **A wrong comparison is caught by construction.** The greedy's answer is
  checked for being a genuine subsequence of the bank — a check on the
  *output*, not on the code path that produced it. The hand-written sort is
  checked against hand-worked expected output, not against itself.
- **The trap case is exercised.** `--check` asserts a too-short bank yields the
  sentinel −1 rather than whatever the buffer happened to hold.

### Defect injection — 19 injected, 19 detected

`./inject.sh` copies `day03.y`, applies one `sed` mutation, rebuilds with the
pinned compiler, and requires the property check to fail. Nothing outside
`/tmp` is touched. Result: **18 caught by an assertion, 1 caught by a trap, 0
uncaught, 0 skipped.**

```
  caught    greedy-pop-flips                   71 of 128 FAILED
  caught    greedy-keep-ignores-drop           40 of 128 FAILED
  caught    greedy-drop-off-by-one             84 of 128 FAILED
  caught    greedy-reverses-digits             74 of 128 FAILED
  caught    window-ignores-lookahead           32 of 128 FAILED
  caught/trap window-edge-one-too-far            runtime error: index out of bounds
  caught    dp-drops-the-skip-term              9 of 128 FAILED
  caught    dp-wrong-power                     53 of 128 FAILED
  caught    dp-empty-is-impossible             53 of 128 FAILED
  caught    parse-bank-length-off-by-one        3 of 128 FAILED
  caught    anchor-expectation-off-by-one       1 of 128 FAILED
  caught    anchor-part2-off-by-one             1 of 128 FAILED
  caught    rescan-sees-no-banks                2 of 128 FAILED
  caught    banks-expected-off-by-one           4 of 128 FAILED
  caught    short-bank-accepted                 2 of 128 FAILED
  caught    subsequence-test-inverted           1 of 128 FAILED
  caught    sort-runs-backwards                 5 of 128 FAILED
  caught    sort-drops-the-carried-index        2 of 128 FAILED
  caught    greedy-broken-crosscheck-vacuous   39 of 128 FAILED

injected 19 defects: 18 caught by an assertion, 1 caught by a trap, 0 uncaught
```

Three of these are worth calling out:

- **`window-edge-one-too-far`** looks one battery too far (`hi = n - t + 1`),
  which reads `d[off + n]` — out of bounds. The mutant **traps** instead of
  failing an assertion. That still fails the check loudly (non-zero exit,
  report truncated mid-line), so it is counted, and it is labelled as a trap
  rather than dressed up as a clean catch. It is also the honest reason the
  real `hi` is `n - t`: it is the only value that cannot run off the end.
- **`greedy-broken-crosscheck-vacuous`** applies **two** mutations: it breaks
  the greedy *and* replaces the real input's three-way cross-check with
  greedy-versus-greedy. The concern it exists to answer is the one from
  `ORCHESTRATOR.md` §7: a check that compares a value with itself. It is still caught
  (39 failures), because the anchors, the micro-cases and the exhaustive sweep
  are independent of that loop.
- **`rescan-sees-no-banks`** is the exact vacuity trap: it makes the
  independent byte rescan count nothing. It fails as `got 0, want 200` — which
  is precisely why the expected count comes from the shell and both counts are
  asserted non-zero.

### Two bugs the check caught while it was being written

1. **The DP scored a too-short result as a k-digit one.** With `best(n,j) = 0`
   for "no such choice", the lone 9 in `811111111111119` sat in the tens place
   and scored **90**, beating the true **89** — and the DP's part-1 total came
   out 17388 against the greedy's 17383. Fixed with an explicit `IMPOSSIBLE`
   sentinel. Without the brute force in the sweep, a plausible wrong number
   would have shipped.
2. **My own hand arithmetic was wrong twice**, and the check was right both
   times. `819191911111111` at *k*=12 is **991911111111**, not the
   919191911111 I first asserted (I had stopped the window at the wrong
   column). And fixture A's shift count is **17**, not 18 — I had counted a 9
   as "smaller than 9". Both expectations were corrected after redoing the
   arithmetic by hand, not by adjusting them to fit the output.

## Numbers

Measured on this machine, every process under `ulimit -S -v 3670016`.

| | |
|---|---|
| whole program, 200 banks × 100 digits | ~1.2 ms per run (200 consecutive runs: 0.238 s wall) |
| peak RSS | 2064 KB |
| one `max_k_greedy(k=12)` pass over all 200 banks | **182 µs** (≈9 ns/digit) |
| `--check` (incl. the 30948-pair exhaustive sweep, 294132 brute leaves) | ~26 ms per run |
| **heap allocated by the hot loop** | **0 bytes over 100 passes** (`--bench`: `heap_used` 735784 → 735784) |
| compile | clean, **zero warnings** |

`--bench` exists to make that last row checkable rather than asserted: the heap
is an arena, so a literal array or string built inside a loop would show up as
a rising `heap_used()`.

## Compiler constraints honoured, and the one workaround

- **No `float`, no `float`→`long`, no cast syntax, no math functions.** There is
  no floating point anywhere in this program; all arithmetic is integers.
- **No `sort`** — `sort_desc` is mine, and it is asserted on (§[5]).
- **No `break`, no `continue`** — early exits are guard flags; loops that need
  to skip wrap the body in a positive condition.
- **No literal array or record inside a loop body.** Every working buffer
  (`STACK`, `ROW_A`, `ROW_B`, `OUTBUF`, `SMALL`, `WIN`, `VALS`, `WHO`,
  `HIST_A`, `HIST_B`) is a module-level global, initialised once. Measured
  cost of that discipline: 0 bytes over 100 passes.
- **No `>>>`** — the program contains no `>>>` at all (a logical shift on a
  possibly-negative value would be silent and catastrophic; there is nothing
  here to shift).
- **`str +=` is never the last statement of a braced block.** The one string
  append in a loop is `while (j <= CAP) { big += "1"; j = j + 1 };`, where the
  `;` is *inside* the braces — the fast form.
- **No `str` + `byte`.** A `str[i]` is a `byte` and `str + byte` segfaults, so
  digit validation converts to a `long` first (`let c = s[j]` then
  `c - CH_0`) and messages are built with `tostring`, never by concatenation.
- **`main()`'s return value is not the exit status.** The driver ends with
  `def main() -> long { ... }; exit(main())`, so every error path really exits
  1.
- **Runtime traps print to stdout**, so no error path may trap. Every refusal
  is `eputs` + `return 1`. Verified on ten paths, all exit 1 with an empty
  stdout: missing file, empty file, too-few batteries, non-digit, rating below
  1, a bank one digit past the cap, unknown option, `--input` with no
  argument, two input files, and a 1025-digit bank. A 1024-digit bank succeeds.
- **No shared state with a sibling day**, and nothing is imported from one. The
  only import is `fs`, a std unit.

One language limitation was worked around, and it is **already filed** — see
`SUGGESTIONS.md` §12, *"A `[byte; N]` does not unify with `[byte]`, and a `*byte`
cannot be walked"*. A fixed-length array is its own type, so a parameter
declared `[long]` rejects a `[long; 1024]`:

```
error: 'max_k_greedy' arg 0: expected [long], got [long; 8]
```

The diagnostic is clear and the fix is local: the buffers that get **passed** to
a function are declared plain `[long]` (`let SMALL: [long] = [0; 8];`) while the
ones that stay module-level keep their fixed size. Same limitation, same
element type, so §12 covers it — **no new filing was made.**

**No compiler bug was found.** The compiler's diagnostics were correct and
specific throughout. Two compile errors were hit and both were my own mistakes:
`self` inside `brute` refers to `brute` (4 parameters), not to `brute_from`, so
the helper is now called by name; and the fixed-array unification above.

## The frozen toolkit

`examples/_toolkit/` (`fx.y`, `term.y`, `fb.y`, `args.y`, `time.y`) is **not**
vendored here, and no sha is recorded, because this example uses none of it:
there is no floating point (so no `fx`), no trigonometry, no terminal, no raw
mode, no keyboard, no frame pacing and no argument parsing beyond `argv()`. The
folder therefore has exactly one source file, `day03.y`, and one std import.

## Determinism

`./day03` reads only `input.txt`, touches no clock, no terminal size, no
network and no random source, and needs no `--seed`: the input is fixed. The
golden run is byte-identical twice (gate item 2 verifies this). `--check` and
`--bench` are likewise deterministic; only `--bench` reads the clock, which is
why it is behind a flag and is not the gate's `run=`.

## `input.txt` is gitignored, on purpose

`input.txt` is per-account personal data. `.gitignore` in this folder keeps it
out of git because the repo's `!examples/**/*.*` rule would otherwise
re-include it. No session cookie is in any file here. `EXPECTED` contains only
two integers and the shape of the input — no bank digits.

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
