# day10 — Advent of Code 2025, day 10 ("Factory"), in Y

One self-contained example: parses the day-10 input, solves **both** parts,
prints both answers, and carries a property battery (`--check`) that does not
use the golden file at all.

```
build: ../../../refs/ycc.ref day10.y -o day10      # three levels up, not four
run:   ./day10                                      # input.txt -> both answers
       ./day10 --check                              # property battery
       ./day10 --help
```

The pinned compiler is **`refs/ycc.ref`**, sha256
**`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**
(matches `refs/SHA256SUMS`). The pin moved twice while this example was being
written (`c53cc415…` → `6dcd7071…` → `4a58dd5d…`); the build and `EXPECTED`
were redone at each move and the output is byte-identical under all three.
Nothing outside this folder is imported, embedded or read: `input.txt` is a
copy of `examples/aoc/inputs/day10.txt`, and `.gitignore` keeps it (and only
it) out of git, because puzzle inputs are per-account personal data.

---

## The puzzle, in my own words

The Elves' factory has machines that are switched off. The manual's
initialisation procedure was eaten, so all that is left is, per machine, one
line of notation:

```
[.#...] (0,2,3,4) (0,1,3,4) (0,3,4) {220,13,8,220,220}
```

- `[...]` — the **indicator lights**: one character per light, `.` off and
  `#` on. Every light starts **off**.
- `(...)` — one **button wiring**: the indices of the lights that press
  toggles. A press turns each listed light on if it was off and off if it was
  on. Several wirings, so several buttons.
- `{...}` — the **joltage** requirements: one number per counter, every
  counter starting at **zero**. Part 1 says these can be ignored.

Pushing a button an even number of times undoes itself on the lights.

**Part 1** asks, summed over all machines, for the fewest button presses that
leave every machine's indicator lights matching its diagram.

**Part 2** turns the joltage numbers into the puzzle: each press adds 1 to
every counter its wiring lists, and the fewest total presses must land every
counter on its target *exactly*. Part 2's wording is not in the public
statement (it is login-gated) — see **Part 2's rule and its anchor** below.

The real input is 156 machines, 1124 buttons, 4–13 buttons and 4–10 lights per
machine, joltage levels up to 275.

## The answers

| | answer |
|---|---|
| **part 1** | **425** |
| **part 2** | **15883** |

`./day10` prints them, plus the facts they rest on:

```
machines: 156
buttons: 1124
part 1 (fewest presses to match the indicator diagrams): 425
part 2 (fewest presses to reach the joltage targets): 15883
worst machine: 9 presses for part 1, 293 for part 2
cross-checks: meet in the middle agreed on 156/156 machines, 156/156 press
certificates replayed, the counter-subset bound proved part 2 optimal on 76/156
memo peak: 210 states
```

Runtime **40 ms**, peak RSS **4.1 MB** (the cap is 3.5 GB). The solve phase
allocates **14 384 bytes in total** for all 156 machines — see
**Allocation**.

---

## How the two parts work

### Part 1 — every subset

Pressing a button twice toggles its lamps straight back, so **an optimal
solution presses each button at most once**: if a solution presses some button
twice, deleting two presses leaves the lamps identical and the total two
lower. Part 1 is therefore the smallest subset of buttons whose XOR of masks
equals the diagram. The scan builds every subset's pattern in one table using
the standard recurrence — *the pattern of `s` is the pattern of `s` without its
lowest set bit, XOR the mask of that bit* — so all 2ⁿ subsets cost O(1) each.

That lemma is a theorem, and theorems rot, so `--check` also runs a
**definition-faithful** search that allows repeated presses and never assumes
the lemma (below).

### Part 2 — the halving recursion

Lamp *i* and joltage counter *i* are **the same index**: a wiring naming `0`
toggles light 0 *and* bumps counter 0. (Verified against three independent
write-ups; see below.) So the counters still missing an **odd** amount say
exactly which lamps must end up on.

Let `f(t)` be the fewest presses that raise every counter by the residual
`t`. Press **once** each button of any subset whose XOR is the parity pattern
of `t`. What is left over is then **all even** — halve it, and recurse: the
same buttons again cost exactly double and change no lamp. So

```
f(t) = min over subsets c with pattern(c) = parity(t), c ≤ t, of  |c| + 2·f((t − c)/2)
f(0) = 0        f(t) = −1 if no candidate works
```

This is u/tenthmascot's recursion, published at
<https://reddit.com/comments/1pk87hl> and explained at
<https://aoc.winslowjosiah.com/solutions/2025/day/10/>. Every subset is
grouped by its lamp pattern once per machine (count → prefix sum → fill, three
linear passes, no sort), so looking up "every subset with this pattern" is a
range. The recursion is memoised on the residual vector by a hash of it —
**with the key compared in full on every hit**, so a collision can cost time
but cannot change an answer, and `--check` tests that claim rather than
asserting it.

Worked by hand, machine 1 (`[.#...] (0,2,3,4) (0,1,3,4) (0,3,4) {220,13,8,220,220}`,
answer 220) — parity `01000`, the only subset with that pattern is `{1,2}`:

```
(220,13,8,220,220)  −(0,1,3,4) −(0,3,4) = (218,12,8,218,218)  all even → /2
(109,6,4,109,109)   −(0,3,4)            = (108,6,4,108,108)   all even → /2
(54,3,2,54,54)      −(0,1,3,4) −(0,3,4) = (52,2,2,52,52)     all even → /2
(26,1,1,26,26)      −(0,2,3,4) −(0,1,3,4) = (24,0,0,24,24)   all even → /2
(12,0,0,12,12)      −∅                 = (12,0,0,12,12)      → /2
(6,0,0,6,6)         −∅                 = (6,0,0,6,6)         → /2
(3,0,0,3,3)         −(0,3,4)           = (2,0,0,2,2)         → /2
(1,0,0,1,1)         −(0,3,4)           = 0                   → f = 0
```

Reading the chain back up, `1, 3, 6, 12, 26, 54, 109, 220`: presses at depth
*d* are worth 2^*d*, which is why the answer is **220**, not the 8 presses the
path shows. `jwalk` uses exactly that weighting, which is what makes the press
certificate below an honest one.

---

## Part 2's rule and its anchor

**The rule came from write-ups, not from AoC.** Part 2 is behind the login, and
the public statement says only that the joltage requirements "can be safely
ignored". Three independent sources describe part 2 identically, and my
implementation reproduces all three's claims:

- **u/tenthmascot** (Reddit) / **Josiah Winslow**
  (<https://aoc.winslowjosiah.com/solutions/2025/day/10/>): the halving
  recursion, which is what this program does.
- **jcmoyer** (<https://forum.ada-lang.io/t/2025-day-10-factory/4034>): the
  same puzzle as an integer program — minimise `Σ x_b` subject to
  `A x = b`, `x ≥ 0` integer, over the matrix whose column *b* is button *b*'s
  wiring — solved by row-reducing and searching the free variables. They
  publish an optimum of **223** for one machine of their own input, *and* the
  press vector for it.
- **Stephen Cerruti** (<https://scerruti.github.io/AoC2025/writeups/day10/>)
  and **Lojic Technologies**
  (<https://blog.lojic.com/2025/12/11/advent-of-code-2025-day-10-factory/>):
  the same integer program (ILP, and LP via SciPy). Lojic's `assert`ed
  answers (475 / 18273) are for *their* input, not this one.

### Anchor tiers — which one this reaches

- **Part 1: tier 1 (external).** The statement's own worked example: three
  machines, 2 + 3 + 2 = **7** presses. `--check` parses those three lines and
  asserts 7. This is a value somebody else published, for the statement's own
  example, so it validates the interpretation *and* the implementation.
- **Part 2: tier 1 for the rule and for the implementation, tier 2 for the
  statement's own example.** I could not find a published part-2 answer *for
  the statement's example* (three searches; the sample's part-2 number appears
  to be nobody's blog post). What I do have is better in one way and weaker in
  another:
  - **external, non-trivial:** jcmoyer's machine
    `[.##.##] (4,5) (0,5) (2,3) (1,3,5) (0,3,5) (0,2,3,5) (0,1,4) (0,2,4,5) {198,181,22,50,173,65}`
    with their published optimum **223** — and this program produces 223, *and*
    their published press vector `0,0,1,24,20,5,157,16` replays against my
    parser to exactly those targets. A misreading of "toggle vs increment" or
    of "minimise the total" breaks that number, so this is real external
    validation of part 2.
  - **self-derived (tier 2):** the statement's example totals **33** for part
    2 (10 + 12 + 11). This is *my* reading, so it is circular about the
    interpretation; it is confirmed by the definition-faithful search and
    printed by `--check`.

**Residual risk, honestly.** The interpretation risk is low but not zero: the
rule is externally sourced from three sources that agree, and reproduced
against a third party's published optimum computed by linear algebra. What I
cannot rule out is that AoC's real part 2 says something subtly different —
e.g. that a press should *also* be required to leave the lights correct, which
these sources say it does not. Two of the three sources state explicitly that
the lights are ignored in part 2, so I believe it, but it is a belief.
The other risk is the *implementation on the real input*: the two independent
methods below agree on all 156 machines, 156 press certificates replay, and a
relaxation proves minimality outright on 76 of them — but for the other 80 the
minimality argument is the recursion's own, cross-checked rather than proved.
For what it is worth, a throwaway Python solve written independently from the
write-ups agrees exactly: 425 and 15883.

---

## Why a hand-rolled scanner, and not `import regex;`

I wrote a **byte-level scanner** (`parse_machine`, plus `find_from`,
`wiring_mask`, `joltage_list`) and did **not** use the `regex` module. Why:

1. **The work is splitting, not matching.** There is nothing to match. A
   record is `[`…`]`, then zero or more `(…)`, then `{…}`; the interesting
   decisions are *which byte closes this record* and *is this field a number*.
   A regex would have to re-find the delimiter anyway.
2. **The delimiters are three different characters.** `[`, `]` and `{`, `}`
   are not interchangeable, so a pattern like `\[[^\]]*\]` has to be spelled
   once per bracket kind and a mistake is a silent mis-parse. The scanner
   reads one delimiter at a time and a wrong one is an error message.
3. **`split()` drops exactly one trailing empty field.** This is called out in
   the campaign briefing and it bit: `"{1,}".split(",")` is `["1"]`, so a
   trailing comma is *invisible* — `"1,"` would silently parse as one counter.
   A regex cannot help either (you would still be splitting on `,`), so the
   fix has to be explicit anyway: the scanner checks the last byte for a comma
   before splitting. `SUGGESTIONS.md` #18 covers the neighbouring gap —
   `str.index_of` takes no start offset, so `find_from` is hand-rolled rather
   than `line[i:].index_of(")") + i` (which allocates, and whose off-by-one is
   silent).
4. **Cost.** The scanner is ~90 lines and allocates nothing per record; the
   regex route would have been shorter to write and slower per record, and it
   would have made the *error messages* ("byte 120 in the indicator diagram is
   neither '.' nor '#'", at a line and column) much worse.

The parser is driven by the data, not by an assumed grammar: it takes spaces
anywhere between tokens and inside a record, refuses anything it does not
recognise, and validates what it read (every index a wiring names must have a
lamp *and* a counter; no empty wiring; no non-decimal field; a joltage level
in range). `--check` exercises sixteen accept/refuse cases, including the
three bracket kinds and the `split()` trap.

## Allocation

The heap is an arena: nothing is freed, so a literal array inside a loop
would leak per iteration. **Every buffer is a module-level literal,
allocated once** (`bbuf`, `jbuf`, `tbuf`, `spat`/`ssiz`, `gpat`/`gsize`/`gsub`/
`gstart`/`gfill`, the memo's three arrays, and the meet-in-the-middle tables).
`[0; n]` takes only a literal size — `SUGGESTIONS.md` #8 — which is why the
bounds are constants (`MAX_BUTTONS = 13`, `MAX_LIGHTS = 11`, …) rather than
derived. The only per-machine allocations are the 156 `Machine` records and
their two small arrays. Measured with the `heap_used()` builtin:

| point | heap |
|---|---|
| after module init | 2 782 856 B |
| after parsing 156 machines | 3 403 168 B |
| after solving all 156 | 3 417 288 B |

so the whole solve costs **14 384 B** — about 92 bytes a machine, all of it
the `Machine` copy. Peak RSS 4.1 MB against a 3.5 GB cap.

## Limits, and what happens at each

Each is a **message on stderr and a non-zero exit**, never a trap. Verified by
running each path:

| limit | value | why there | over the limit |
|---|---|---|---|
| `MAX_BUTTONS` | 13 | part 1 enumerates 2ⁿ subsets (8192) | `more than 13 buttons; this solver enumerates 2^13 subsets` |
| `MAX_LIGHTS` / `MAX_COUNTERS` | 11 | bitmasks stay under 2¹¹ for the pattern table | `an indicator diagram longer than 11 lights` |
| `MAX_JOLTAGE` | 2²⁰−1 | 20 halvings; `DEPTH_MAX` is 24 | `joltage level '...' is outside 0..1048575` |
| `MEMO_CAP` | 16384 | 210 states peak on the real input | **not an error**: the memo stops caching and the search gets slower, never different. `--check` proves it by re-solving everything with 512/128/64 slots |
| `MAX_MACHINES` | 2048 | the per-machine answer table | `... holds more than 2048 machines` |
| battery | 240 machines | `--check` time (0.46 s) | — |

## The property check (`./day10 --check`)

A golden file proves determinism, not rightness, and an AoC answer is a
single integer that a wrong algorithm reproduces perfectly. So `--check` runs
**71 assertions with no reference file involved**, and every one of them is
either hand-worked in this README, published by the statement or a third
party, or computed a second way.

Its actual output:

```
$ ./day10 --check
day10 --check: property battery (no reference file involved)
  anchors: statement example for part 1, a published machine for part 2
  real input: 171 machines
  micro-cases:            9 machines, 22 hand-computed assertions
  parser cases:           16 accept/refuse assertions
  part 1 meet-in-middle:  169 machines agree with the exhaustive scan
  part 1 definition-faithful: 149 machines
  part 2 definition-faithful: 22 machines
  part 2 certificates:     172 press vectors replayed exactly
  part 2 lower bound:      169 <= answer, tight on 89 (76 of them real machines)
  memo under collisions:   513 solves with 512/128/64 slots, same answers
  permutation oracle:      684 reordered/relabelled runs
  generated battery:       240 machines, seed 20251210
  checks run: 71, failed: 0
--check OK
```

### The hand-computed micro-cases

Nine machines, twenty-two assertions. Each is worked out here so a reader can
check the arithmetic without running anything.

| machine | part 1 | part 2 | why |
|---|---|---|---|
| `[#.] (0) (1) {1,1}` | 1 | 2 | press `(0)`: lamp 0 on, lamp 1 off — done in one. Counter 0 needs `x₀=1`, counter 1 needs `x₁=1`, so 2 presses |
| `[##] (0) (1) (0,1) {1,2}` | 1 | 2 | press `(0,1)`: both lamps on. Counter 0 = 1 forces `x₀+x₂=1`, so `x₂=1,x₀=0`, and counter 1 = `x₁+x₂=2` gives `x₁=1`: 2 presses. Pressing only `(0)` twice and `(1)` twice would be 4 |
| `[....] (0) (1) {0,0}` | 0 | 0 | every lamp already off and every counter already met — the zero case, where **0 is the answer** and a naive "answer ≥ 1" invariant is wrong |
| `[#.#] (0,1) (0,2) (1,2) {2,3,1}` | 1 | 3 | press `(0,2)`. The three counters give `x₀+x₁=2`, `x₀+x₂=3`, `x₁+x₂=1`; summing gives `Σx=3`, hence `x₂=1, x₁=0, x₀=2` — 3 presses, and no other solution has fewer |
| `[#] (0) (0) (0) {3}` | 1 | 3 | three identical buttons: any one press does part 1, but counter 0 needs three presses, whichever button supplies them |
| `[#.#] (0) (2) {1,0,1}` | 2 | 2 | press both buttons for part 1. Counter 1's target is 0 and no button touches it, so it must stay — the same line shows a counter that must NOT move |
| `[#.] (0) (1) {0,2}` | 1 | 2 | **the case part 1's lemma forbids and part 2 demands**: counter 0 must stay at 0, so `(0)` is never pressed and `(1)` is pressed **twice**. Part 1 = 1, part 2 = 2 |
| `[#] (0) {0,1}` | 1 | **−1** | counter 1's target is 1 and no button touches it: unreachable. Must be *reported*, not trapped |
| `[#.#] (0) (1) {1,1}` | **−1** | 2 | the reachable patterns are `{}` and `{0}`; `{0,2}` is not among them: an unreachable diagram is reported, not trapped |

Two of my hand answers were **wrong the first time** and the program was right:
I had written "part 1 = 2" for micro 1 and "part 1 = 2, part 2 = 4" for micro
4. Pressing `(0)` alone finishes micro 1, and micro 4's system of equations
solves to 3. Per the campaign rule — *if a property check disagrees with your
answer, the check is right until you prove otherwise* — the expectations were
corrected, not the code, and both corrections are in the table above.

### The oracles, and which is which kind

The rule from `day05`: **at least one oracle must differ in kind from the
solver**, because that day shipped a bug where every method agreed with every
other on the same wrong answer and only a check that *permutes the input*
caught it.

1. **Meet in the middle** (all 171 machines). A different *algorithm*:
   O(2^⌈n/2⌉) with a linear probe over 128 halves, and it shares no code with
   the scan — its own tables, its own recurrence. Catches a wrong subset
   enumeration immediately (defect D17).
2. **Definition-faithful search, part 1** (149 machines, plus all 240 battery
   machines). Minimises `|x|` over **integer press counts `x ≥ 0`** by
   depth-first search with iterative deepening, using the XOR of the
   *odd-count* buttons. No subset lemma, no bitmask enumeration: this is the
   statement's wording searched literally. It is what actually tests part 1's
   lemma, and it is affordable only when the answer is small (≤ 4 presses).
3. **Definition-faithful search, part 2** (22 machines of the real input,
   where the answer is ≤ 28, plus all 240 battery machines). Minimises `|x|`
   over `x ≥ 0` with `A x = t` **exactly**, by depth-first search on the press
   counts. No parity argument, no halving, no memo — just the rule. This is
   the oracle that would catch a misread of part 2 itself.
4. **The press certificate** (all 171 machines). `jwalk` retraces the
   recursion's own choices — weighted by 2^depth — into an actual press
   vector, and `verify_certificate` then **replays it from the statement's
   wording**: every counter starts at 0, one press adds 1 to each counter its
   button lists. All 172 vectors land exactly on the targets and sum to exactly
   the reported answer. This is a *witness*, so it catches a wrong answer even
   where minimality is only argued.
5. **The counter-subset lower bound** (all 171 machines). For any set `S` of
   counters, the presses landing on `S` sum to `Σ_{j∈S} t_j`, and each press
   lands on at most `max_i |wiring_i ∩ S|` of them, so `|x| ≥ ⌈Σ_S / that⌉`;
   maximised over all 2^k sets it is a bound no solution can beat. It holds on
   every machine and **equals** the answer on 76 of the 156 real machines,
   which *proves* minimality for them. `--check` asserts it stays tight on at
   least 70, so weakening the bound is caught (defect D15).
6. **The permutation oracle** (684 runs). Four transformations of every
   machine — buttons reversed, buttons rotated by one, buttons in adjacent
   pairs swapped, and the index space relabelled (counter *i* → *n−1−i*, lamp
   *i* likewise, which is a relabelling of the statement's shared index space)
   — and **every machine's two answers must be unchanged**. This is the check
   that differs in kind from every other one: it does not re-derive the answer,
   it changes the *order* and demands the same result. It catches defects D04
   and D07, which are day05's exact shape: take the first or last candidate
   instead of the best, and every other method still agrees with itself.
   `solve_permuted` also checks the index map really is a permutation before
   trusting it — the first version of "adjacent pairs swapped" was *not* one,
   and silently dropped a button.
7. **The memo under collisions** (513 extra solves). The same answers from a
   table of 512, 128 and 64 slots — small enough to collide, and at 64 slots
   small enough to fill. Plus a **planted** collision: a slot is forced to
   claim a hash whose stored key differs, and the lookup must miss. Without
   that, "the key is verified on every hit" was a claim nothing exercised.
8. **Invariants** (every machine). `0 ≤ part 1 ≤ nbuttons`; `part 1 = 0` **iff**
   the diagram is all off; `part 2 = 0` **iff** every target is zero; the
   bound never exceeds the answer; every certificate replays; meet in the
   middle agrees; and **exactly** the two machines built to be unsolvable are
   unsolvable — no machine of the real input may report −1.
9. **The generated battery** (240 machines, seed 20251210). Machines built
   from a fixed seed (1–5 lamps, 1–5 buttons, random wirings, targets 0–5),
   each solved **through the same `solve_machine` the real run uses** — so a
   defect injected into the solver is injected for the check — and compared
   against *both* definition-faithful searches. 240 machines × 2 oracles × 2
   parts = 960 comparisons in 0.2 s.

   The generator is **`import random`** (`src/y/std/random.y`, splitmix64) —
   `random.seed(20251210)` then `random.below(n)`. It used to be a module-level
   `rng_s` stepped by `(s * 1103515245 + 12345) % 2147483648` behind a local
   `rnd(n)`: the textbook glibc LCG, which is biased for every `n` that is not
   a power of two. The battery is unchanged in strength — it asserts nothing
   about a *particular* machine, so a different stream is a different 240
   machines rather than a different set of expectations — and `EXPECTED` does not
   move at all, because the generator is reached only from `--check`.

**Route through one entry point.** Everything goes through `solve_machine(idx)`
and the `--check` synthetic machines are parsed by the *same* `parse_machine`
the real run uses. No oracle re-implements the pipeline.

## Defect injection: 21 defects, 21 caught

Each defect is a small edit to `day10.y`; the mutant is built, run, and then
checked. The script is throwaway (`/tmp`, not shipped); the table is the
evidence.

| id | defect | answers | caught by |
|---|---|---|---|
| D01 | part 1: subset `s` derived from `s−1` instead of `s` without its lowest bit (**day05's bug class**) | run exits 1 | statement anchor, part-1 anchor |
| D02 | part 1: XOR turned into OR (a toggle turned into "turn on") | run exits 1 | statement anchor, part-1 anchor |
| D03 | part 1: the diagram test inverted | run exits 1 | part-1 anchor, published machine |
| D04 | part 1: the **last** matching subset instead of the smallest | run exits 1 | part-1 anchor, published machine |
| D05 | part 2: the halving factor dropped from the recursion's cost | run exits 1 | part-2 anchors |
| D06 | part 2: the "a counter went negative" refusal dropped | **changed** | `--check` does not finish in 300 s |
| D07 | part 2: the **first** working combo instead of the cheapest (**day05's bug class**) | **changed** | part-2 anchors |
| D08 | part 2: the parity test inverted | run exits 1 | statement anchor, part-2 anchors |
| D09 | part 2: the certificate walk stops weighting levels by 2^depth | unchanged | micro 4/5/7 certificates |
| D10 | parser: every joltage digit read one too high | run exits 1 | statement anchor, part-2 anchors |
| D11 | parser: the lamp bit for `#` shifted one place right | run exits 1 | statement anchor, part-1 anchor |
| D12 | parser: the **wiring** trailing-comma guard neutered | unchanged | two parser assertions |
| D12b | parser: the **joltage** trailing-comma guard neutered | unchanged | `'{1,}' is rejected` |
| D13 | parser: spaces inside a joltage record no longer tolerated | unchanged | parser assertion |
| D13b | parser: spaces inside a wiring no longer tolerated | unchanged | parser assertion |
| D14 | the memo's key verification always says "same key" | unchanged | the planted-collision assertion |
| D15 | the lower bound weakened until it stops proving minimality | unchanged | the "≥ 70 machines tight" assertion |
| D16 | parser: the "a wiring past the counter list" refusal removed | unchanged | two parser assertions + the unsolvable count |
| D17 | meet in the middle: the right half forgets its buttons | run exits 1 | the invariants (mitm differs) |
| D18 | part 2: the recursion gives up at depth 3 | run exits 1 | statement anchor, part-2 anchors |
| D19 | part 2: the first subset in each parity group skipped | run exits 1 | statement anchor, part-2 anchors |

**Defects that altered no answer**, listed rather than quietly dropped:

- **D09, D12, D12b, D13, D13b, D14, D15, D16** (8 of 21) leave 425 and 15883
  exactly where they were, and are caught only by the property battery. That is
  the point of the battery: D09 is a broken certificate, D15 is a bound that
  has quietly stopped proving anything, D13/D13b are a parser that has quietly
  stopped accepting a shape it promised — none of which an answer can see.
- **D06** is caught by *not finishing*: dropping the negative-counter refusal
  makes `--check` diverge rather than fail. Worth naming as a rough edge of the
  check itself — a hang is a detection, but a slow one.
- **D06 and D14 also made the compiler warn** (`'ok2' is assigned to itself`,
  unreachable code) — the linter flagged both without being asked.

## What to look at

1. `solve_part1` — the subset recurrence, and the comment saying what getting
   it wrong looks like.
2. `jrec` — eleven lines that are the whole of part 2: the parity pattern, the
   group lookup, `|c| + 2·f(...)`.
3. `jwalk` and `verify_certificate` — the 2^depth weighting, and the replay
   that makes the answer a witness.
4. `parse_machine` — the scanner, and the four validations after it.
5. `d1_rec` / `d2_rec` — the two definition-faithful searches. Reading them
   next to `solve_part1` / `jrec` is the clearest statement of what "a
   different kind of check" means here.
6. `check_permutations` and `is_permutation` — the day05 lesson, and the guard
   that stops the oracle itself from lying.

## Compiler workarounds, and where they are filed

| what | why | where |
|---|---|---|
| `[0; n]` takes a literal size, so every buffer is a module-level literal with a constant bound | the runtime-sized array is wanted | `SUGGESTIONS.md` #8 (pre-existing) |
| `str.index_of` has no start offset; `find_from` is hand-rolled | the scanner needs "the next `)` from here" without a copy | **`SUGGESTIONS.md` #18** (filed by this example) |
| `split()` drops exactly one trailing empty field | `{1,}` and `(0,)` would parse as one entry; the scanner checks the last byte for a comma | campaign briefing, "Array operators"/`split`; the guards are `wiring_mask` / `joltage_list` |
| no `break`, no `continue` | early exit and "skip" are guard flags and positive conditions | `ORCHESTRATOR.md` §2.9; e.g. the battery's `!solvable` / `solvable` split |
| `main()`'s return value is not the exit status | `def main() -> long { … }; exit(main())` is the working idiom | `SUGGESTIONS.md` #15 (pre-existing) |
| runtime traps print to **stdout** | every diagnostic goes through `eputs`, so a trap cannot silently corrupt `EXPECTED` | campaign briefing, trap #3 |

**No compiler bug was found.** Nothing is filed in `BUGS.md`: no crash, no
miscompile, no bad diagnostic, and the compiler's own linter caught two of the
injected defects unprompted. The only filing is suggestion #18.

## Files

| file | |
|---|---|
| `day10.y` | the whole example — 1 file, no imports beyond `fs` |
| `input.txt` | the day-10 input, vendored (gitignored) |
| `EXPECTED` | the deterministic output of `./day10` |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |
| `README.md` | this file |
| `.gitignore` | keeps `input.txt` out of git |

No vendored toolkit files: this example is a parser and two solvers, so it uses
none of `fx.y`/`tui`/`args` and there are no shas to
record. The frozen-toolkit revision is therefore not applicable here.
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
