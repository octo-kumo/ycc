# `sandfall` — a falling-sand cellular automaton in the terminal

Sand, water, oil, fire, smoke and stone on a grid with a ghost border of stone
on every side, stepped one generation at a time, drawn through a framebuffer
with per-material colour, and dumped as text under `--no-tty`. Deterministic by
default; `--seed` (default 1) drives the one scene that uses randomness — and
that randomness now comes from **`import random`** (`src/y/std/random.y`,
splitmix64) rather than from the 63-bit LCG this folder used to carry in
`grid.y`. Same seed ⇒ byte-identical grid, exactly as before; the *bit stream*
is different, so `terrain` is a different (equally ragged) cavern under every
seed. No other scene draws at all, which is why `EXPECTED` — the `basin` run —
does not move.

**The rule that decides the physics is stated up front, because in a falling-sand
automaton it is not an implementation detail:**

> One generation is **one scan** of the interior cells — rows **bottom to top**,
> left to right within a row — updating the grid **in place**. When the scan
> reaches a cell it reads what is there *at that moment*, not what was there
> when the generation began. Each material tries its moves in a fixed order and
> takes the first that succeeds, and a per-generation **stamp** guarantees that
> **no grain moves twice in one generation**.

Everything below is a consequence of that paragraph, and `--check` asserts each
of them.

```
$ ./sandfall --no-tty --size 56x22 --frames 40
sandfall -- falling sand, in place, one scan a generation

  scene        : basin
  grid         : 56 x 22, plus a one-cell ghost border of stone on every side
  store        : 58 x 24 = 66564 cells, fixed at compile time
  scan order   : rows bottom to top, left to right, in place, at most one move per grain
  seed         : 1
  frames       : 40
  initial      : stone 168  sand 36  water 56  oil 28  fire 1  smoke 0

  generations  : 40
  last change  : the last generation
  final        : stone 168  sand 36  water 56  oil 0  fire 0  smoke 16
  moved last   : 10
  empty cells  : 956
  ghost border : 160 stone cells, which is the whole border (160)
  matter       : 276 of 1232 cells

final frame (the ghost border is the one-cell frame around it):
##########################################################
#                                     .......            #
#                                                        #
#                                            .           #
...
##########################################################
##########################################################
##########################################################
##########################################################
```

## Build and run

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
cd /home/yun/Projects/compiler/examples/sandfall
(ulimit -S -v 3670016; $YCC sandfall.y -o sandfall) </dev/null
```

The four vendored toolkit modules and `grid.y` / `scene.y` / `props.y` are
imported by bare name from this directory, so the folder builds on its own with
nothing else present.

```sh
./sandfall                                   # the live view (alt screen, 30 fps)
./sandfall --no-tty --frames 40              # headless: a table and the final frame
./sandfall --no-tty --scene drip --size 60x24 --frames 120
./sandfall --no-tty --scene terrain --seed 7 --frames 200 --stats
./sandfall --check                           # the property check
./sandfall --help
```

**The documented deterministic run** — `EXPECTED` is the exact stdout of

```sh
./sandfall --no-tty --size 56x22 --frames 40
```

```sh
./sandfall --no-tty --size 56x22 --frames 40 </dev/null | cmp - EXPECTED && echo same
sh capture.sh && git diff --exit-code         # regenerating moves nothing
```

## Options

| flag | meaning |
|---|---|
| `-s, --scene NAME` | `basin` (default), `drip`, `firestorm`, `terrain`, `empty` |
| `-z, --size WxH` | the logical grid; `80x` means square, the default is the terminal size minus its border and status line. At most 256 × 256 |
| `--seed N` | the seed for `--scene terrain`; same seed ⇒ byte-identical grid |
| `-f, --frames N` | run exactly N generations headless, print the table and the frame, exit 0 |
| `--no-tty` | never touch the terminal |
| `--dump N` | print the grid as text every N generations (at most 8 frames) |
| `--fps N` | the live view's frame cap (default 30, `0` = uncapped) |
| `-c, --color MODE` | `mono` (a grey ramp) or `color` (truecolour) |
| `-S, --stats` | elapsed time, µs/generation, heap delta, whether the final frame is a fixed point, and the checksum |
| `--check` | run the property check and exit — **no reference file involved** |

Exit codes: **0** ran (or `--help`), **1** every diagnostic. Diagnostics go to
**stderr** and never to stdout, which is what lets `EXPECTED` be diffed: a
runtime trap prints on *stdout* in Y and would corrupt the diff silently
(`ORCHESTRATOR.md` §2.6).

### Keys (live view)

`q` `Esc` `Ctrl-C` quit · `space` pause · `.` one generation · `n` next scene ·
`r` reseed (`seed+1`) · `c` mono/colour · `+` `-` speed · `h` the key list.

---

## What to look at

- **`grid.y`'s header, "THE RULE, WRITTEN OUT"** — the scan order, why
  bottom-to-top is what stops sand teleporting, what the stamp is for, and the
  **proof that no run is infinite**. It is the whole example in one comment.
- **`grid.y:step()`** — the generation loop. Two things guard the body instead
  of `continue`, which does not exist in Y (`ORCHESTRATOR.md` §2.9): the stamp
  test and the material test are positive conditions around the work, and the
  scan has no early exit at all — it is exactly *h*×*w* cells every generation,
  whether or not anything can move.
- **`grid.y:liquid_move()`** — the sideways rule, and the "at least **two**
  lower" asymmetry that buys a strictly decreasing potential. The obvious rule
  (any lower column) has a **period-2 cycle** in a two-column box: levels
  (2,1) → (1,2) → (2,1). That is a limping, not a fixed point, and it would
  make "a closed box reaches a fixed point" false.
- **`grid.y:sand_move()`** — the two diagonals require the cell *beside* the
  grain to be free as well, so a grain needs room to slip past its neighbour.
  `inject.py` found that this rule had been documented in the comment and *not
  implemented*, and C2e exists because removing it changed nothing the suite
  could see.
- **`scene.y`** — the five scenes, all rectangles and straight lines of
  arithmetic, so their cell counts can be worked out by hand. It is its own
  module because `props.y` imports it: one copy of every scene, so the check
  cannot end up testing a different builder from the one the program runs.
- **`sandfall.y:winsize()` and the `sb_*` family** — the two places where the
  obvious spelling allocates and the fixed-buffer one does not. Both carry the
  measurement that found them (§ *Measurements* below).
- **`props.y`'s header** — the three defences against the vacuous pass, and what
  each of C0…C11 is for.
- **`inject.py`** — the 18 injected defects, which two of them the suite could
  not see, and why one of those is provably equivalent rather than a hole.

## The scenes

| scene | what it shows |
|---|---|
| `basin` | a sand heap, a water pool and a burning oil slick, all on one stone floor: sand piles at its angle of repose, water levels out into a pyramid, fire eats the oil and the smoke rises to the ceiling |
| `drip` | one stone column under a stream of water: the clearest demonstration that water falls, spreads *sideways*, and does not pile — the pool at the bottom is symmetric |
| `firestorm` | a deep oil pool with a fire in the middle and a sand bank downwind: the fire consumes exactly the oil it touches, the smoke rises, and the bank slumps into a 45° talus |
| `terrain` | the **seeded** scene: a ragged stone cavern and a shower of sand and water over it. The only scene `--seed` changes |
| `empty` | a bare box, for measuring |

Three things worth checking by eye:

```sh
./sandfall --no-tty --scene drip      --size 60x24 --frames 120   # the pool is symmetric
./sandfall --no-tty --scene firestorm --size 60x24 --frames 200   # oil -> 0, fire -> 0, bank at 45 degrees
./sandfall --no-tty --scene terrain   --size 80x30 --seed 7 --frames 300 --stats
```

---

## Measurements

**No allocation in the generation loop, and none in the live path either** —
both read with `heap_used()` at both ends of the loop, and the delta is zero:

```
$ ./sandfall --no-tty --stats --size 80x24 --frames 20000
  per generation: 6.4 us, 153924 gen/s
  heap         : 1013944 -> 1013944, growth 0 bytes over 20000 generations
  fixed point  : yes -- the final frame is already a fixed point
  checksum     : 1916622272005784837
```

**Throughput**, three runs each, on the shared machine this was written on:

| grid | cells | per generation | generations/second |
|---|---|---|---|
| 80 × 24 | 1 920 | 6.3 – 7.0 µs | 141 000 – 157 000 |
| 200 × 100 | 20 000 | 45.4 – 45.5 µs | 21 900 – 22 000 |
| 256 × 256 | 65 536 | 138.0 – 139.2 µs | 7 180 – 7 245 |

That is ~330 M cell-visits/second at 200 × 100 with bounds-free indexing (the
ghost border) and a store of `byte`s. Heap growth is 0 at every size.

**The live view holds 30 fps.** Through a pty at 24 × 80, after four seconds
`--stats` reports

```
sandfall: 4100 ms, 122 generations, 29 fps, 0 frames dropped by the pacer
sandfall: heap 2581448 -> 2581448, growth 0 bytes over 121 generations
```

29 is `fps_avg_x100 / 100` truncated from 29.8 — the pacer is the limit, not the
simulation, which manages 154 000 generations/second on that grid.

**The interactive path, under a real pty.** `tmux` is not installed here, so
`pty_check.py` allocates one from Python — the same harness `tui` was verified
with. Seven sessions, 26 checks: `q`, `Esc`, `Ctrl-C`, a mid-run `TIOCSWINSZ`,
the remaining keys, the no-terminal refusal, and a `SIGKILL`. Each must exit
correctly, leave the alt screen, show the cursor and put the termios back.

```
1. 'q' quits
  ok   alt screen entered  [b'\x1b[?1049h\x1b[?25l\x1b[']
  ok   the grid was drawn
  ok   frames drawn  [20676 bytes in 1.2 s]
  ok   no other program's escape sequences in the stream
  ok   exit code 0  [0]
  ok   alt screen left
  ok   cursor shown again
  ok   raw mode was actually entered while running
  ok   termios restored on exit
...
6. no terminal: refuses with a message, exits 1, writes no escapes
  ok   exit code 1  [1]
  ok   the message names the reason  [sandfall: not a terminal; try --frames N --no-tty]
  ok   nothing at all on stdout, so EXPECTED cannot be corrupted by a diagnostic
7. kill -9 mid-run: tui's watchdog still restores the terminal
  ok   the process really was killed  [-9]
  ok   the terminal was restored by something other than the program's own cleanup
all checks passed
```

```sh
python3 pty_check.py ./sandfall
```

**No traps on any path.** 23 invocations across every flag, a bad value for
each, an unknown scene, four grids too small for their scene, a grid larger than
the store, and an unexpected operand — every one exits 1 with a specific message
on stderr, an empty stdout, and **zero** `runtime error:` lines. A sample:

```
--size 0x0        rc=1 trap=0 | sandfall: --size '0x0': a grid must be at least 4x4 -- the ghost
--size 40x9z      rc=1 trap=0 | sandfall: --size '40x9z': the height '9z' is not a number
--size 999x999    rc=1 trap=0 | sandfall: --size '999x999': at most 256x256, because the store i
--seed 99999999   rc=1 trap=0 | sandfall: --seed 99999999: must be between 0 and 1000000
--scene nope      rc=1 trap=0 | sandfall: unknown scene 'nope'; expected basin | terrain | drip
--color nope      rc=1 trap=0 | sandfall: --color must be mono or color (got 'nope')
--fps 5000        rc=1 trap=0 | sandfall: --fps 5000: must be between 0 and 1000
--scene basin --size 8x8
                  rc=1 trap=0 | sandfall: --scene basin needs a grid at least 11 rows tall
extra-operand     rc=1 trap=0 | sandfall: unexpected operand 'extra-operand'; everything is an o
```

Note that `--seed -1` and `--frames -5` are refused by `args` with *needs a
value* rather than reaching this program's range check, because a leading `-`
looks like an option. `--seed=-1` and `--frames=-5` do reach it and are
diagnosed by name. Both spellings are shown above because the difference is
worth knowing.

---

## The property check — the part that matters most

A golden file proves **determinism**, not rightness: `cube` in this campaign
passed every gate item while rendering a defect, because its `EXPECTED` had been
generated from the broken output. So `--check` asserts things about behaviour
with **no reference file anywhere**, and it can be seen to fail —
`inject.py` exists for that.

```
$ ./sandfall --check
...
RESULT PASS -- 139 assertions, 0 failed, 26675 generations, no reference file
```

The whole transcript is kept in **`CHECK.txt`**, so a reader does not have to run
anything to see what it claims.

The assertions come from `import test` (`src/y/std/test.y`), not from this
folder: `props.y` used to define its own `ck(cond, what)` and `ck_num(got, want,
what)`, and they are gone — std's `test.ck(name, ok, detail)` and
`test.ck_eq(name, got, want)` took their place, with every call site reordered
to match, the tally now read from `test.checks()` / `test.failures()` instead of
two module-level counters, and one deliberate asymmetry: `test.report()` is *not*
called, because the `RESULT PASS` line above already summarises the run and it
carries the generation count as well. `CHECK.txt` was regenerated, so the
indentation of every assertion line and the position of every `ck_eq`'s numbers
moved; the assertions themselves are identical and the count is the same.

| group | what it asserts |
|---|---|
| **C0** | non-vacuity: the box really has stone, sand and water on it *before* anything is counted, and the counts are printed |
| **C1** | stone, sand and water conserved at **every** generation of a 300-generation run, plus `matter + empty == w*h` — against literals in `props.y`, not against `grid.CNT[]` |
| **C2a** | one sand grain falls **exactly one row per generation**, for a literal number of generations, and is still there 10 later |
| **C2b** | a four-grain stack's top advances one row per generation while it has room — a column does **not** compact in one step |
| **C2c** | no grain crossed more than one column or fell more than one row in a single generation, over 30 generations of a drop — and **both bounds are tight**, so the bound is not passing because nothing moved |
| **C2d** | every cell a grain *arrived at* (identified by the stamp) had that material beside it in the previous generation |
| **C2e** | a grain in a one-cell pocket cannot drain out of it |
| **C3** | a closed box reaches a **fixed point** — a generation that changed nothing — and then 20 further generations leave the checksum bit-identical, with the checksum non-zero and matter still on the grid |
| **C4** | monotone invariants at **every** generation: `sum(sand y)` and `sum(water y)` never decrease, `sum(stone y)` never moves, the topmost sand never rises, the volatile total never grows, fire never touches stone or sand |
| **C5** | the exact trajectory of a single grain over 17 generations, and that it moved up on **none** of them |
| **C6** | water spreads: a poured column ends up across ≥ 3 columns, centred on where it was poured to within 2, with adjacent columns differing by ≤ 1 and no run of more than 1 empty column inside it |
| **C7** | determinism: seed 1 twice is one checksum, seed 7 twice is one checksum, and seed 1 ≠ seed 7 — or `--seed` is a lie. Plus generation 0 and generation 50 of a third seed |
| **C8** | `heap_used()` flat across 20 000 generations **and** across 2 000 `step`+`tally` pairs, with `GEN` asserted to have advanced by exactly that many so a skipped loop cannot pass |
| **C9** | every store cell outside the logical grid is stone, at every generation, over 250 generations of `basin` and 2 000 of `firestorm` |
| **C10** | a **second, independent counter** — the grid rendered to a string and the string's bytes counted — agrees with the array tally, and the per-column levels sum to the water count |
| **C11** | the suite made ≥ 90 assertions, examined cells, exercised > 1 000 generations, and failed none of them |

### Why this is not the vacuous pass

Two agents in this campaign shipped checks comparing two values that were *both
absent*, and `wavefunction`'s author flagged a third shape: a conservation check
that reads its pre-count and post-count from the same buggy counter is `0 == 0`
wearing a conservation costume. Three defences, and the first two are structural:

1. **No expected value is read from the code under test.** Every total is
   arithmetic over literals in `props.y`:

   ```
   stone = BW * FLOOR_H                              = 40 * 2 = 80
   sand  = (SAND_X1-SAND_X0+1) * (SAND_Y1-SAND_Y0+1) = 10 * 5 = 50
   water = (WATER_X1-WATER_X0+1)*(WATER_Y1-WATER_Y0+1)=  7 * 6 = 42
   ```

   `grid.CNT[]` is only ever the *observed* side of a comparison.
2. **Two independent paths for every count.** C10 counts the sand again by
   rendering the grid to a `str` and counting the `'o'` bytes, which shares no
   code with the byte-array tally. `inject.py`'s `tally-skips-a-column` proves
   the pair has teeth: breaking the array counter lights up **C0, C1, C2, C4,
   C6, C9 and C10**.
3. **An observed value is asserted present and non-zero *before* it is
   compared.** C0 for every material, C3 for the fixed point's checksum, C7 for
   both seed checksums, and C6 for **every measurement helper** — see below.

### Three ways this suite got it wrong first, and what each one cost

These are the most useful things in the folder, so they are written down rather
than quietly fixed.

- **`water_span(xl, xh)` never wrote the caller's variables.** Y passes
  parameters **by value**, so every C6 measurement was computed from
  `x = 0..0, y = 0..0`: the hole count was 0 because it scanned **one cell**,
  the surface relief was 0 because both ends were 0, and three assertions
  passed **vacuously, on nothing**. The helpers now live in module state (Y has
  no out-parameters), and C6 asserts each measurement non-zero *before* using
  it. This is the "both values absent" failure, reached by a completely
  different route.
- **"Is the source cell empty now?" is unobservable.** The first C2d asked
  whether a grain's origin was empty at the end of the generation. Ten cells out
  of 483 real moves failed it, all at the bottom of a settling pool. The reason:
  a grain that vacates a cell leaves it empty but does **not** stamp it, so a
  grain scanned later in the same row moves straight in, and the cell ends the
  generation looking untouched. The check was asserting something no observer
  can see. What *is* observable is the stamp — a cell stamped this generation is
  precisely a cell something arrived at — and C2c now uses that.
- **A stale tally read as a live one.** C4's fire section read its starting
  volatile total *before* taking a tally, so it got the **previous** grid's
  number (0, because the previous grid was the fire-free one) and then reported
  29 generations of "the volatile total grew".

### The injected defects

```
$ python3 inject.py
baseline: RESULT PASS -- 139 assertions, 0 failed, 26675 generations, no reference file
baseline EXPECTED: reproduces

defect                       check   EXPECTED  groups
------------------------------------------------------------------------------------
scan-row-order               CAUGHT  CHANGED   C11, C2, C6
scan-column-order            EQUIVALENT  CHANGED   -
no-stamp                     CAUGHT  CHANGED   C11, C2
stamp-never-resets           CAUGHT  CHANGED   C11, C2, C3, C4, C5, C6
sand-drains-sideways         CAUGHT  unchanged C11, C2
no-ghost-border              CAUGHT  CHANGED   C1, C10, C11, C9
liquid-level-1               CAUGHT  CHANGED   C11, C3, C4, C6
smoke-never-vanishes         CAUGHT  unchanged C11, C3, C4
changed-ignores-age          CAUGHT  unchanged C11, C3
settled-detection            CAUGHT  unchanged C11, C3, C6
fire-eats-stone              CAUGHT  CHANGED   C11, C4, C9
level-bookkeeping-sign       CAUGHT  CHANGED   C10, C11, C4, C6
literal-in-the-loop          CRASH   unchanged --
        runtime error: out of memory
literal-per-generation       CAUGHT  unchanged C11, C8
seed-ignored                 CAUGHT  unchanged C11, C7
tally-skips-a-column         CAUGHT  CHANGED   C1, C10, C11, C2, C4, C6, C9
fixture-count-from-counter   CAUGHT  unchanged C1, C10, C11, C4
fixture-glyph-wrong          CAUGHT  unchanged C10, C11

18 defects injected: 16 CAUGHT by an assertion, 1 CAUGHT only as a crash or a hang,
1 PROVEN EQUIVALENT, 0 slipped through unchecked
9 of the detected ones left EXPECTED byte-identical: the golden could not see those,
only the property check could.
```

**Nine of the seventeen detected defects reproduce `EXPECTED` byte for byte.**
That is the point: the golden is blind to all of them, and only the property
check sees them.

The one **provably equivalent** mutation is `scan-column-order`, and the argument
is worth reading in full (it is also in `inject.py`):

> Reversing the within-a-row scan changes the trajectory — `EXPECTED` moves — but
> **all 139 assertions still pass.** The reason is that the *stamp* already
> bounds every grain to one cell per generation, so the within-a-row order has
> nothing left to decide except which of two grains competing for one cell wins.
> That is a tie-break, and the suite asserts invariants and bounds rather than a
> specific trajectory — pinning the trajectory would make `--check` a golden file
> wearing a costume. The **row** order is not in that class: scanning top to
> bottom changes what a grain can reach before its cell is revisited, and it is
> caught. Removing the stamp is caught too. So the pair
> {right-to-left, no-stamp} together is the observable defect, and each alone is
> not.

`literal-in-the-loop` (a `[long; 8]` literal inside the **innermost** loop) is
detected, but as an **out-of-memory trap** rather than by C8's heap assertion:
64 bytes per *cell* per generation reaches the 3.5 GiB cap long before the check
gets to C8. The canonical form — a literal in the generation loop's own body, 64
bytes a row — *is* caught by C8, and reports the numbers:

```
FAIL heap growth over those generations, in bytes (got 66560000, want 0)
FAIL heap growth over 2000 step+tally pairs, in bytes (got 6656000, want 0)
```

---

## The std units this uses

Vendored copies, byte-identical to `test/std/`, **not edited** — the
(there is nothing left to diff -- the files are gone):

`fx.y` is **not** vendored: there is no trigonometry, no square root and no
float anywhere in a falling-sand automaton. Four modules is the honest set.

**Compiler pin.** `refs/ycc.ref`, sha256

```
9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7
```

**The pin moved while this example was being built.** The folder was created and
first built against `4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`
and reblessed twice more during the work, ending at the sha above. Everything was
re-verified against the current one from source: clean build with **zero
warnings**, `EXPECTED` byte-identical over two runs, no trap on any of the 23
error paths, heap delta 0 over 20 000 generations and over a 121-frame live
session, `pty_check.py` 26/26, `--check` 139 assertions 0 failed, and
`inject.py` 18/18. `EXPECTED` did not move when the pin did, which is worth
knowing but is not evidence of correctness -- hence the property check.

---

## Language notes: every workaround, and where it lives

Nothing here needed the compiler patched. Each of these is a shape the language
asked for, and the code says so where it applies.

1. **No character literals.** `'q'` is a *lexer* error. The live view compares
   `ord("q")` and friends. Not filed: the absence of a feature is a suggestion
   at most, and the root `TODO.md` already covers literal syntax.
2. **`[0; N]` takes an integer literal only**, so a grid cannot be allocated at
   its own size: `[0; w * h]` is a compile error. The store is therefore four
   fixed `[byte; 66564]` / `[long; 66564]` arrays with a logical `w`/`h`, which
   is also what the arena wants — allocated once, never resized — and
   `--size` above 256 × 256 is a clean diagnostic instead of a 3.5 GiB guess.
3. **No `break`, no `continue`.** Both are undefined names. `grid.step()` wants
   both: the stamp test and the material test are **positive conditions** around
   the work, and the scan's "are we done" lives in the caller's guard flag
   (`run_live`'s `running`, `run_until_settled`'s `settled`, the report's
   `dump_every`/`dumped` counter). Three of this file's own loops were written
   with a missing increment first and hung forever; `props.y`'s loop audit and
   the 0.24 s runtime are the evidence that they are all right now.
4. **A block's value is its last statement without the `;`** — so
   `def … -> bool { x < y; }` is an error, and two one-line predicates here are
   written the other way. The tell is that the error names the return type.
5. **`exit()` is `void`,** so a `def … -> long` ending in `exit(1)` is a type
   error. `die(msg) -> long` returns the code and the call site is
   `exit(die("…"))`, which cannot forget half the diagnostic.
6. **`s[i]` on a `str` is a `byte`**, so the independent counter in `props.y`
   compares `row[i] == 111`, not `== "o"`.
7. **`chr()` is byte-oriented and cannot make a non-ASCII glyph.** Every glyph
   here is ASCII for exactly that reason (`' '` 32, `'#'` 35, `'.'` 46, `'='`
   61, `'@'` 64, `'o'` 111, `'~'` 126), which also keeps `EXPECTED` a text file
   anyone can read in a diff.
8. **`read_key_timeout(ms)` cannot be finer than 100 ms**, because `VTIME`
   counts deciseconds and any non-zero request rounds *up*. The live view polls
   with **0** and lets `tui`'s pacer own the deadline; `run_live` says so at
   the call site.
9. **`main()`'s return value is not the exit status.** `main();` discards it and
   the program exits 0, so an error path that did `return 1` would look
   successful. The idiom here is `def main() -> long { … return 0 }; exit(main())`.
10. **No out-parameters, and no unknown types**, so a function that has to
    return two measurements writes module state — the same discipline `grid.y`
    uses for its level arrays — and its caller asserts the result is non-zero
    before comparing it. Both halves of that lesson are in the C6 comment.
11. **A record returned by a function allocates on every call.** `term.size()`
    answers `{rows, cols}`, a fresh record (~40 B), so polling it once a frame
    leaked 40 bytes a frame for ever. The frame loop calls this file's own
    `winsize()` instead: the same `TIOCGWINSZ` ioctl (syscall 16, fd, request,
    argument — kernel register order, §2.1; rows first, bytes 0–1, §2.3) into a
    module-level `[byte; 8]`, packed as `rows * 1000 + cols`. The frozen
    `tui` copy is not edited; `default_size()` still uses `term.size()`,
    because it is called once.
12. **`str +=` amortises, but building a number as a string does not.** The
    status line began as an f-string plus three concatenations (~2.4 KB a
    frame), and then as `sb_num` prepending `char(48 + u % 10) + d` — correct,
    and one string allocation *per digit*. The live view leaked **413 bytes a
    frame** (`growth 50432 bytes over 122 generations`) and `--stats` was the
    only thing that said so. `sb_num` now counts the digits and writes them
    most-significant-first straight into the module-level `[byte; 256]`: no
    allocation, and O(d²) on a number of at most ten digits.
13. **A literal array or record inside a loop body costs 64/40 bytes per
    iteration** and the heap is an arena. Nothing in `step()` or anything it
    calls builds a literal; the eight neighbours of `fire_step` are written out
    as straight lines precisely so that a `[long; 16]` offset table is not
    needed in the hot path. C8 asserts the heap is flat, and `inject.py`
    demonstrates that the assertion fires.
14. **A `[T; N]` is not a `[T]`.** The tally helpers take and return scalars for
    exactly this reason, and the C6 measurements write module state instead of
    returning an array.
15. **The quadratic `str +=`, audited rather than eyeballed.** Compiled with
    `-S` and every `call y_str_app` (the amortised, *discarded*-position append)
    and `call y_str_cat` (the exact-size copy, a *value-used* position) located,
    together with whether each one sits inside a loop — which is decided by
    finding a backward jump to a label at or before it, not by reading the
    source. The program as a whole: **12 `app`, 388 `cat`**, and:

    | site | in a loop? | verdict |
    |---|---|---|
    | `grid.step()` and everything it calls | **no string operation at all** | nothing to be quadratic |
    | `store_row_text`, `props.count_glyph` | 1 `app` each | amortised O(1) — this is the intended shape |
    | `counts_line` | 1 `app`, 3 `cat` | a **7-iteration** loop, once per report |
    | `dump_gen`, `run_headless`'s frame printer | 1 `cat` per **row** | bounded by the grid height, and `--dump` prints at most 9 frames |
    | `run_live` | 2 `cat` | both inside `die(msg)`, on the diagnostic paths: at most once, and then the program exits. The measured heap delta over 121 live frames is **0** |
    | `props.c2_order`, `c5_down_only`, `c7_deterministic` | 3–6 `cat` each | one per assertion, a few hundred in total |

    So there is no `cat` in an unbounded loop anywhere. The trap the brief warns
    about — `str +=` as the last statement of a braced block — is the shape
    `{ out += x }` versus `{ out += x; }`, and **neither** spelling appears in
    this program: the only `+=` in a loop is `store_row_text`'s per-cell append,
    which is discarded and amortised, and `sb_num` writes digits into a
    `[byte; 256]` instead of building a string at all (note 12).

## Files

| file | what |
|---|---|
| `sandfall.y` | the entry point: flags, `--size` parsing, the headless report, the live view, `winsize()`, the status line |
| `grid.y` | the store, the materials, **the physics**, `step()`, the tally, the checksum; `srand`/`rnd_below` are now two-line wrappers over `import random` |
| `scene.y` | the five built-in scenes, shared with `props.y` |
| `props.y` | the property check: C0…C11, no reference file, assertions from `import test` |
| `gate.conf` | `build=`, `run=`, `check=` — the deterministic invocation whose stdout is `EXPECTED` |
| `capture.sh` | regenerates `EXPECTED` and `CHECK.txt` from the pinned compiler |
| `pty_check.py` | seven pty sessions, 26 checks |
| `inject.py` | 18 injected defects, and the equivalence argument |
| `EXPECTED`, `CHECK.txt` | the documented run, and the property check's whole transcript |
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
