# AoC 2025, day 1 — "Secret Entrance", in Y

A dial numbered `0`–`99` starts pointing at **50**. Your input is a list of
rotations, one per line: a direction (`L` toward lower numbers, `R` toward
higher) and a distance in clicks. The dial is a circle, so one click left
from `0` lands on `99` and one click right from `99` lands on `0`. Apply
every rotation in order.

* **Part 1** — how many rotations leave the dial pointing at `0`?
* **Part 2** — how many individual **clicks** leave it pointing at `0`? (The
  click that ends a rotation counts here too, so part 2 ≥ part 1; the
  difference is the clicks that pass *through* 0 in the middle of a rotation.)

## Answers (real input, `input.txt`)

| | |
|---|---|
| rotations | 4 432 |
| total clicks | 622 933 |
| **part 1** | **1066** |
| **part 2** | **6223** |
| final dial position | 13 |

## Build and run

```sh
cd examples/aoc/day01
../../../refs/ycc.ref day01.y -o day01     # build
./day01                                    # both answers, from input.txt
./day01 --check                            # the property battery
./day01 --help
./day01 --input example.txt                # the statement's worked example
```

`EXPECTED` is the byte-exact stdout of `./day01` (221 bytes).

**Pinned compiler** — `refs/ycc.ref`, sha256

```
c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

That is the only compiler used here, and the only one that may be. Note the
path is `../../../refs/ycc.ref` — **three** `..`, not four:
`day01 → aoc → examples → compiler`. (The task paragraph's
`../../../../refs/ycc.ref` resolves to `examples/refs/ycc.ref`, which does not
exist.)

## What to look at

| in `day01.y` | why it is interesting |
|---|---|
| `wrap` | one helper every other function leans on; `%` truncates toward zero, so a circular index needs the negative fixed up by hand |
| `hits_in` | the whole of part 2 as one exact division — O(1) per rotation |
| `part2_per_click` vs `part2_closed` | the two independent implementations of part 2 that `--check` compares |
| `part1_walk` vs `part1_reverse` | the two independent implementations of part 1 (forward and wrapping, versus backward and exact) |
| `rescan` | a second reader for the same file that never calls `read_lines` or the parser |
| `micro`, `check_hits_exhaustive`, `check_periodicity` | the property battery |

## Data

`input.txt` is this account's personal AoC input. It is vendored here so the
folder is self-contained, and this folder's `.gitignore` keeps it out of git
(the repo's `!examples/**/*.*` would otherwise re-include it; the campaign's
shared copy at `examples/aoc/inputs/` has its own ignore rule).
`example.txt` is the statement's published worked example — public data.

## The property check — `./day01 --check`

An AoC answer is one integer, and a wrong algorithm reproduces it perfectly,
so `EXPECTED` proves determinism and nothing else. Every assertion below has
an expectation that comes from **outside** the code under test: worked out by
hand, published by the statement, or produced by a second implementation. No
golden file is involved.

Real output, all 36 checks:

```
ok   micro statement example   part1=3 part2=6 closed=6 reverse=3 final=32 want 3/6
ok   micro statement example methods agree   part1=3 part2=6 closed=6 reverse=3 final=32 want 3/6
ok   micro statement L10 wrap   part1=1 part2=2 closed=2 reverse=1 final=0 want 1/2
ok   micro statement L10 wrap methods agree   part1=1 part2=2 closed=2 reverse=1 final=0 want 1/2
ok   micro L100 from 50   part1=0 part2=1 closed=1 reverse=0 final=50 want 0/1
ok   micro L100 from 50 methods agree   part1=0 part2=1 closed=1 reverse=0 final=50 want 0/1
ok   micro R100 from 50   part1=0 part2=1 closed=1 reverse=0 final=50 want 0/1
ok   micro R100 from 50 methods agree   part1=0 part2=1 closed=1 reverse=0 final=50 want 0/1
ok   micro L50 from 50   part1=1 part2=1 closed=1 reverse=1 final=0 want 1/1
ok   micro L50 from 50 methods agree   part1=1 part2=1 closed=1 reverse=1 final=0 want 1/1
ok   micro L999 from 50   part1=0 part2=10 closed=10 reverse=0 final=51 want 0/10
ok   micro L999 from 50 methods agree   part1=0 part2=10 closed=10 reverse=0 final=51 want 0/10
ok   micro R999 from 50   part1=0 part2=10 closed=10 reverse=0 final=49 want 0/10
ok   micro R999 from 50 methods agree   part1=0 part2=10 closed=10 reverse=0 final=49 want 0/10
ok   micro L0 while at 0   part1=2 part2=1 closed=1 reverse=2 final=0 want 2/1
ok   micro L0 while at 0 methods agree   part1=2 part2=1 closed=1 reverse=2 final=0 want 2/1
ok   hits_in == click-by-click, exhaustive   2 directions x 100 positions x 201 distances, 0 mismatches
ok   hits_in gains exactly 1 per revolution   2 directions x 100 positions x 201 distances, 0 mismatches
ok   input readable   4432 lines, 18205 bytes
ok   input well formed   4432 rotations, none malformed
ok   rotations present   n=4432
ok   clicks present   clicks=622933
ok   rescan present   n=4432 clicks=622933
ok   parse == rescan   4432/622933 vs 4432/622933
ok   directions == rescan   L:2236/2236 R:2196/2196
ok   distances == tonum   0 of 4432 disagree with tonum()
ok   part 1 present   part1=1066
ok   part 2 present   part2=6223
ok   part 1: walk == reverse   1066 vs 1066
ok   part 2: per-click == closed form   6223 vs 6223
ok   part 2 == part 1 + inside   6223 == 1066 + 5157
ok   final position == wrap(START + sum)   13 == 13 (sum -18237)
ok   part 1 <= rotations   1066 <= 4432
ok   part 2 <= clicks   6223 <= 622933
ok   part 1 <= part 2   1066 <= 6223
ok   final position in 0..99   13

real input: part 1 = 1066, part 2 = 6223, final = 13

property check: 36 checks, all passed
```

Exit status 0. Any failure prints a `FAIL` line naming the check and exits 1;
a runtime trap would print `runtime error:` on stdout and also exit non-zero,
so a trap cannot be mistaken for a pass.

### 1. Hand-computed micro-cases

**A — the statement's own worked example** (also shipped as `example.txt`).
`./day01 --input example.txt` prints `3` and `6`. The statement publishes the
`3`; the `6` is derived below and independently reproduced by a published
third-party solution. For each rotation, the clicks that land on 0:

| line | from | to | clicks landing on 0 | counts in |
|---|---|---|---|---|
| `L68` | 50 | 82 | 50 | part 2 only |
| `L30` | 82 | 52 | — | |
| `R48` | 52 | 0 | 48 (the last click) | both |
| `L5` | 0 | 95 | — | |
| `R60` | 95 | 55 | 5 | part 2 only |
| `L55` | 55 | 0 | 55 (the last click) | both |
| `L1` | 0 | 99 | — | |
| `L99` | 99 | 0 | 99 (the last click) | both |
| `R14` | 0 | 14 | — | |
| `L82` | 14 | 32 | 14 | part 2 only |

Reading it: for `L68` from 50 the dial counts 49, 48, … and reaches 0 on the
50th click. For `L30` from 82 it never gets near 0 in 30 clicks. For `R48`
from 52 it needs exactly 48 clicks to climb back to 0 — and that is the last
click of the rotation, so the dial is *left* at 0. For `L5` from 0 the dial
goes 99, 98, 97, 96, 95 — it leaves 0 immediately and does not return. For
`R60` from 95 it needs 5 clicks to reach 100 ≡ 0, then 55 more. For `L55` from
55 it needs 55 clicks to fall to 0, the last one. For `L1` from 0: 99. For
`L99` from 99 it needs 99 clicks to come back round to 0, the last one. For
`R14` from 0: 1…14, no return. For `L82` from 14 it hits 0 after 14 clicks and
then goes on to 99, 98, … 32.

**part 1** = three rotations end on 0 (`R48`, `L55`, `L99`) = **3**, which is
the number the statement states. **part 2** = six rows contain a hit = **6**,
of which three are last clicks and three are interior (50, 5, 14) — so
`6 = 3 + 3`, the decomposition the check asserts.

**B — the statement's wrap edge case, as a legal input: `L45`, `L10`, `R5`.**
This is the statement's own "if the dial were pointing at 5, `L10` would cause
it to point at 95, and after that `R5` could cause it to point at 0", reached
from the real start with a legal first move.

| line | from | to | clicks landing on 0 | part 1 | part 2 |
|---|---|---|---|---|---|
| `L45` | 50 | 5 | none (0 is 50 clicks away, > 45) | 0 | 0 |
| `L10` | 5 | 95 | 5 | 0 | 1 |
| `R5` | 95 | 0 | 5 (the last click) | 1 | 1 |

Totals **part 1 = 1, part 2 = 2**. This is the case the two parts exist to
distinguish: `L10` from 5 passes *through* 0 on its 5th click and ends on 95,
so part 1 is blind to it and part 2 is not.

**C — a whole revolution: `L100` (and `R100`) from 50.** Clicks 1…100 walk
49, 48, … 0 (click 50), … 51, 50 (click 100). One hit, and the dial ends
where it started, so **part 1 = 0, part 2 = 1**. This is the edge case the
statement's wrap rule creates and it is why part 1 can be smaller than the
number of times the dial is *at* 0.

**D — half a revolution: `L50` from 50** ends on 0 on the last click:
**part 1 = 1, part 2 = 1**.

**E — the largest distance in the real input: `L999` from 50.** The dial hits
0 every 100 clicks, at clicks 50, 150, 250, … 950 — **10** hits, and the last
one before 999 is at 950 (950 = 9×100 + 50). The dial ends at
50 − 999 = −949 ≡ 51 (mod 100). **part 1 = 0, part 2 = 10.** `R999` is the
mirror image: 10 hits, ending at 50 + 999 = 1049 ≡ 49.

**F — a zero-length rotation, the one interpretive case: `L50`, `L0`.** After
`L50` the dial is at 0. `L0` leaves it at 0. Read strictly — "the number of
times the dial is **left** pointing at 0 after any rotation" — part 1 counts
it; part 2 has no click to count, so it does not. **part 1 = 2, part 2 = 1.**
The real input's smallest distance is **1**, so this reading cannot change
either answer; it is asserted only to pin the behaviour down.

### 2. Independent cross-checks — two methods, one quantity

| quantity | method A | method B | agrees |
|---|---|---|---|
| part 1 | `part1_walk`: follow the dial, wrapping after each rotation | `part1_reverse`: sum every rotation exactly (no modulus anywhere), then walk the list **backwards** deriving each end position as `(50 + total − suffix) mod 100` | 1066 = 1066 |
| part 2 | `part2_per_click`: step every one of the 622 933 clicks and count | `part2_closed`: one exact division per rotation, no stepping | 6223 = 6223 |
| rotations / total clicks | `parse_lines` over `fs.read_lines` | `rescan`, a raw-`[byte]` scan that pulls digit runs out directly and never calls the parser | 4432 / 622 933 both |
| directions | `parse_lines` | the same byte scan counting `L` and `R` bytes | 2236 L / 2196 R both |
| each distance | the hand-rolled digit loop in `digits_value` | the standard library's `tonum()` | 0 of 4432 disagree |

The two part-1 methods differ in *accumulation order and direction*, so an
off-by-one or a sign error in either shows up as a disagreement. The two
part-2 methods differ in *whether they expand the rotations at all*.

### 3. `hits_in` is proved over the whole state space, not sampled

`hits_in(dist, pos, dir)` is the whole of part 2, so it is checked
exhaustively rather than trusted:

* For **both** directions × **all 100** dial positions × every distance
  **0…200** (two full revolutions), it equals a click-by-click count:
  **0 mismatches in 40 200 cases**.
* For those same states, `hits_in(d + 100) == hits_in(d) + 1`: **0 mismatches
  in 40 200 cases**. That is the periodicity of the dial — exactly one hit per
  revolution — and together with the table above it extends the equality to
  *every* distance by induction on `d`: any `d > 200` reduces by repeated
  `−100`, each step removing exactly one hit. So the real input's 999-click
  rotations are covered by the proof even though no case in the table uses one.

### 4. Invariants on the real answer

| invariant | value |
|---|---|
| part 2 decomposes exactly: `part 2 == part 1 + hits strictly inside a rotation` | 6223 = 1066 + 5157 |
| final position equals the exact signed sum, one modulus instead of 4432 of them | 13 == wrap(50 + (−18237)) = 13 |
| part 1 ≤ rotations | 1066 ≤ 4432 |
| part 2 ≤ total clicks | 6223 ≤ 622 933 |
| part 1 ≤ part 2 | 1066 ≤ 6223 |
| final position in 0…99 | 13 |

### 5. Guarding against a vacuous pass

Two agents in this campaign shipped checks that compared two *absent* values
and passed. So, before anything is compared:

* each observed quantity is asserted **present and non-zero** first —
  `rotations present n=4432`, `clicks present clicks=622933`,
  `rescan present n=4432 clicks=622933`, `part 1 present part1=1066`,
  `part 2 present part2=6223`;
* the expected counts are external: the statement's published `3`, and the
  hand arithmetic above — never a number this program computed;
* **11 defects were injected** into copies of `day01.y` and `--check` was
  required to fail each time. All 11 were caught:

| injected defect | caught by |
|---|---|
| `wrap` loses the negative fix | 7 FAILs |
| `hits_in` forgets to wrap `k0` | 7 FAILs |
| `part2_per_click` skips the last click | 6 FAILs |
| `part1_walk` starts at 49 instead of 50 | 10 FAILs |
| `part1_reverse`'s suffix lags one rotation | `runtime error: index out of bounds`, exit ≠ 0 |
| `final_walk` drops the last rotation | `final position == wrap(START + sum)` |
| `part2_inside` off by one rotation | `part 2 == part 1 + inside` |
| `rescan` forgets to count `R` | `directions == rescan` |
| `digits_value` mis-decodes digits | 12 FAILs |
| the periodicity identity claims 2 hits per revolution | `hits_in gains exactly 1 per revolution`, 40 200 mismatches |
| a micro-case's expected value tampered with | that micro-case |

### 6. Error and argument paths (no trap on any of them)

Every one of these prints a message on **stderr** and exits 1 — a runtime trap
would print on stdout and quietly corrupt `EXPECTED` instead:

| invocation | message |
|---|---|
| `./day01 missing.txt` | `cannot read missing.txt` |
| `--input` with no name | `--input needs a file name` |
| `./day01 --bogus` | `unknown option --bogus (try --help)` |
| two input files | `more than one input file given (try --help)` |
| a file of no rotations | `holds no rotations` (an empty file is a wrong file, not the answer 0) |
| a blank line | `line N: empty line` |
| a leading `X` | `line N: expected a leading 'L' or 'R'` |
| a bare `L` | `line N: rotation has no distance` |
| `L1a2` | `line N: non-digit in the distance at column 3` |
| `L 5`, `L-5` | `line N: non-digit in the distance at column 2` |
| more than 18 digits | `line N: distance has more than 18 digits` (a long could overflow) |

Accepted, and checked: a CRLF file, a file with no trailing newline, leading
zeros (`L007` → 7), and distances above 99 (the real input has 999).

## Numbers

| | |
|---|---|
| build | 0 warnings from the pinned compiler |
| `./day01` | 3.3 ms per run including process start (200 runs: 0.657 s) |
| `./day01 --check` | 19 ms per run (20 runs: 0.380 s) — it does 4 020 000 brute-force click iterations for the exhaustive table |
| binary | 23 466 bytes |
| peak RSS | 2 064 KB |
| heap | 670 496 B after reading the input (the 18 205-byte file, split into 4432 strings); the entire solve — 645 093 loop iterations, 622 933 of them click steps — allocates **344 B** more |
| loop allocations | none: no array or record literal appears inside any loop body |

## Toolkit

**Nothing is vendored.** This example needs no `fx` (no floats — every
modulus is an integer), no `term` (no terminal), no `fb` (no framebuffer), no
`args` (four flags are read from `argv()` directly), and no `time`. The frozen
toolkit in `test/std/` is byte-identical and untouched; its shas, if
you want them for a later day, are
`fx.y 4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058`,
tui 07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee`,
tui 95a7663b7f1c7a90ff3756b51e51644ea952c9b671eeca1012b8f64e18589697`,
args cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28`,
tui 6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b`.

## Compiler workarounds

No compiler bug was found. The traps below are language facts, worked around
in `day01.y` and visible there rather than silent:

* **No floored modulo.** `x % 100` truncates toward zero (C semantics), so
  `-949 % 100` is `-49` and a circular index walks off into negatives
  silently — no trap, just a plausible wrong answer. `wrap()` adds the
  fix-up. Filed as a feature request, not a bug:
  `SUGGESTIONS.md` §16.
* **`for x in <array>` does not compile** — `for line in lines {` gives
  `error: expected '..', got '{'`, because `for..in` walks an integer range
  and `foreach (x in expr)` walks a sequence. Already filed:
  `SUGGESTIONS.md` §6, *`for x in <array>` should say so, not `expected '..'`*.
* **`s[i]` on a `str` is already a byte**, so `ord(line[i])` is
  `error: ord string: expected str, got byte`; index directly.
* **`print` appends a newline to every value**, so a trailing `\n` inside the
  string emits a blank line. `eputs` is the stderr counterpart and does *not*
  append one, so messages to stderr keep their `\n`.
* **`main()`'s return value is not the exit status**, so the driver is
  `def main() -> long { … }; exit(main())` and error paths `return 1`. Filed:
  `SUGGESTIONS.md` §15.
* **Floats are absent**, so no fixed-point arithmetic was needed; every
  modulus here is an integer and the dial has no geometry.

## Where the answers come from

The statement page for day 1 is public; part 2 is only served once part 1 has
been submitted, so it was read from a public write-up of the puzzle
(Dyalog's APL blog, 10 December 2025), which states part 2 as counting every
click that points the dial at zero and gives `6` for the statement's example —
which this program reproduces (`--input example.txt`), together with the
`3` the statement itself publishes. The statement's text is paraphrased above
rather than copied.
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
