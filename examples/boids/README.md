# `boids` — Reynolds' flocking in the terminal, in fixed-point Q16

A flocking simulation: every boid looks at the boids inside a radius and
steers by three rules — **separation** (push off anybody crowding you,
weighted 1/d²), **alignment** (turn the way your neighbours turn) and
**cohesion** (head for their centre of mass). Two ways to run it:

```
./boids                                   the live view: alt screen, 30 fps
./boids --no-tty --frames 200             headless: a table and a frame, exit 0
./boids --check                           the property check, 188 assertions
```

The default path is deterministic: the default seed is 1, there is no unseeded
randomness anywhere, and the headless run prints no timings unless `--stats`
says so. Time and randomness live behind `--fps`, `--stats` and `--seed`.

---

## Build and run

```
cd examples/boids
../../refs/ycc.ref boids.y -o boids        # the only compiler used
./boids --help
```

The pinned compiler, `refs/ycc.ref`, at the time of writing:

```
sha256  9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7
```

`refs/ycc.ref` moves on every rebless, so that hash is re-checked at gate time.
If `EXPECTED` stops reproducing, rebuild, re-run `sh capture.sh` and record the
new hash — never fake a match.

Everything is fed `</dev/null` and runs under `ulimit -S -v 3670016`, as the
campaign requires. `gate.py`, `capture.sh`, `pty_check.py` and `inject.sh` all
do that themselves.

### Useful invocations

| what | command |
|---|---|
| the golden (also `gate.conf`'s `run=`) | `./boids --no-tty --frames 200 --boids 120 --size 100x40 --seed 1` |
| the largest flock the store allows | `./boids --no-tty --frames 100 --boids 512 --size 100x40` |
| one rule at a time | `./boids --no-tty --frames 120 --rules sep` (also `ali`, `coh`, `none`, `sep+coh`) |
| frame markers as well as the table | `./boids --no-tty --frames 60 --dump 20` |
| timing, rate and heap | add `--stats` |
| the live view's throughput | `./boids --boids 300 --fps 60 --stats`, then `q` |

### Keys (live view)

| key | what |
|---|---|
| `q` `Esc` `Ctrl-C` | quit — always `restore_all_exit(0)`, so the screen and the terminal come back |
| space | pause / resume |
| `.` | one frame, even while paused |
| `r` | reseed with seed+1 (the same seed always gives the same flock) |
| `1` `2` `3` | toggle separation / alignment / cohesion |
| `0` | all three on |
| `c` | cycle the palette: mono, speed, depth |
| `+` `-` | the fps cap (0 is as fast as it goes) |
| `h` | the key list |

---

## What to look at

**1. `--check` — the property check.** This is the part that matters most. Run
it first:

```
./boids --check          # 188 assertions, exit 0
```

It is not a golden-file comparison and it involves no reference file. Nine
groups, each of which would fail if the logic were wrong:

| group | what it pins |
|---|---|
| 1 | `qmul`/`qdiv`/`q32`, **including the Q16-ratio trap**: `qdiv(2.0, 1.0)` is 131072 while the bare `/` on the same pair is 2, and the bare `/` does not close under `qmul` while `qdiv` does |
| 2 | the fixed-point root: `flock.isqrt` against `fx.isqrt` over 1600 inputs, plus exactness on every perfect square up to 300² and on every square-minus-one |
| 3 | **a hand-computed two-bird case** — two boids 5 units apart on a 3-4-5, and every intermediate constant derived by hand |
| 4 | the three rules **in isolation**, each with its sign asserted: a lone pair must attract (cohesion), a lone pair must repel (separation), three in a line must re-order (cohesion) and must spread (separation) |
| 5 | neighbour counts from geometry — a probe and birds at *known* distances, including the strict-radius boundary |
| 6 | the velocity clamp: reached under a driving seed, and never passed |
| 7 | determinism: same seed, same state, over 250 frames and 1.79 M pairs |
| 8 | the generator: same seed same draws, different seed different draws, and spread out |
| 9 | structure: bounds, flock size, an empty mask, `place()`'s refusals, the torus wrap |

The exact numbers in group 3, and the direction of every assertion, are derived
by hand in the comments and cross-checked by **`oracle.py`** — an independent
integer model of the same arithmetic, in a language with unbounded integers. It
is not used at run time and it is not the code under test; it is how the hand
arithmetic was confirmed rather than guessed.

The derivation, in short, for two boids at (10,10) and (13,14), both still,
separation only:

```
dx = 3 units = 196608 Q16      dy = 4 units = 262144 Q16
d2 = dx*dx + dy*dy = 25 * 2^32 = 107374182400        (a Q32 quantity)
sep_q16 = -dx_q16 * 2^32 / d2_raw = -196608/25 = -7864.32  ->  -7864
        = -dy_q16 * 2^32 / d2_raw = -262144/25 = -10485.76 -> -10485
|sep| = isqrt(7864^2 + 10485^2) = isqrt(171777721) = 13106
desired = sep * maxs / |sep| = (-7864 * 524288) / 13106 = -314588
                                            (-10485 * 524288) / 13106 = -419438
|force| = 524303 > maxs 524288, so the velocity clamp scales it by 524288/524303
v after one step = (-314578, -419426)
```

**2. `inject.sh` — proof that the check can fail.** A check that has never been
seen to fail is not a check, and the recurring failure in this campaign has been
the *vacuous* pass. So `sh inject.sh` patches `flock.y` or `check.y` 19 ways,
rebuilds, and requires that `--check` exits non-zero **and** that the specific
assertion named for that mutation is among the ones that report `FAIL`:

```
  [ 1] separation's sign (push, not pull)            caught: the 1/d^2 separation accumulator x == -7864  [got 7864, ...
  [ 5] qdiv drops the Q16 -- the ratio trap, live    caught: qdiv(2.0, 1.0) == 131072 ...
  [12] diff() always answers 0 -- the vacuous probe  caught: and they really differ boid by boid  [differing boids 0]
  [13] acc_nali() always answers 0 -- both absent    caught: bird 0 sees exactly one neighbour  [got 0, want 1]
  [18] the tally pre-set to 7 -- status must be 7    caught: exit 7, 0 FAIL lines, summary said 7 FAILED
  [19] the tally never counts, with a broken sim    caught: exit 0, 1 FAIL lines, summary said assertions passed, 0 failed
...
injected: 19   caught: 19   missed: 0
```

#19 is the interesting one: it makes an assertion genuinely fail *and* stops
the tally counting, so the program prints `FAIL` lines and exits 0 saying "0
failed". Requiring exit 0 there is the point — it is what a check whose verdict
is not wired to its own assertions does — and requiring a `FAIL` line alongside
is what stops the entry being satisfied by a build that simply passed.

**3. `pty_check.py` — the interactive path, through a real pty.** tmux is not
installed here, so the harness allocates a pty from Python. Nine sessions:
`q`, the frame counter advancing, output scaling with the fps cap, `Escape`,
`Ctrl-C`, a mid-run resize, all the other keys, a long `--stats` run with 300
boids, and an error path *with* a terminal. The frame-counter check is the one
that matters: it guards the trap where a render loop polls the keyboard with a
1..99 ms timeout, `VTIME` rounds it up to 100 ms, every frame lands a period
late and the loop reports ~0.6 fps with the counter stuck on 1. Here it reaches
46 frames in 1.5 s at 30 fps, and 30 fps draws 8× more than 4 fps in the same
wall time.

**4. The isolated-rule goldens.** `golden/rule-sep.txt`, `rule-ali.txt`,
`rule-coh.txt` and `rule-none.txt` are the same world, the same seed, the same
120 boids, with one rule live at a time. The summary lines:

| live rules | final mean \|v\| | final ord/boid | what it does |
|---|---|---|---|
| `sep` | 0.46 | 6.56 | disperses — nobody sees anybody by the end |
| `ali` | 0.90 | 23.58 | turns into a ribbon: everyone converges on one heading, so everyone sees everyone |
| `coh` | 0.31 | 17.25 | collapses: the flock slows to a crawl and packs tight |
| `none` | 0.86 | 8.08 | flies dead straight; every heading never changes |
| all three | 0.42 | 18.39 | a flock: it holds together *and* it moves |

That table is the clearest single demonstration in the folder of what each rule
does, and `--check` asserts the same three behaviours with hand-computed
numbers rather than with pictures.

**5. `errpaths.sh` — the flag-error sweep.** Run it after touching `main()`.

**6. The `max |v|` column in the table.** It must never exceed the `max speed`
header. That is the velocity clamp, and the header says so; a number above the
cap in that column would be a bug, not a tuning choice. Note that the *default*
configuration never reaches the cap (the summary prints `steps at clamp 0`) —
the flock cruises at 65% of it and the cap is there for the separation spikes.
Lower `--maxspeed` and it bites; `--check` group 6 drives it there deliberately
and asserts both that the clamp fired and that nothing ever passed it.

---

## How it works

```
boids.y     the driver: flags, validation, the live view, the window-size ioctl,
            the status line, the palette
flock.y     the simulation: the store, the per-pair neighbour loop, the three
            rules, the steering, the clamp, the torus, the seeded generator
report.y    the headless report: a fixed-byte line writer, the per-frame table,
            the final frame as text
check.y     the property check
oracle.py   an independent integer model of flock.y's arithmetic (not compiled,
            not run by anything -- it is how the hand constants were confirmed)
```

### Why Q16 and not Q30

`fx.y` is Q30 and is used here — but only for *geometry* (`fx.atan2` in
`flock.heading`), never for the store. The neighbour loop forms
`dx*dx + dy*dy` once per **pair** and takes a root of it, and that product has
to stay inside a signed 64-bit long:

```
Q30   dx = 256 units * 2^30 = 2^38    dx*dx = 2^76    OVERFLOW
Q16   dx = 256 units * 2^16 = 2^24    dx*dx = 2^48    fine; two terms = 2^49
```

So the store is Q16 (`1.0 == 65536`), the world is capped at 256×128 whole
units, and a squared distance is a **Q32** quantity — which is what makes the
hand-computed numbers come out. Q16 resolves a world unit to 1/65536 of it and
one unit is one character cell on screen, so the smallest thing a boid can do
here is 60000× finer than a pixel.

### The three arithmetic helpers, and the trap they exist for

`a / b` on two fixed-point values is their **ratio**, not a scaled quotient:
`2.0 / 1.0` in Q16 is `2`, not `131072`. So there are exactly three helpers and
no bare division of a fixed-point value anywhere:

```
qmul(a, b) = a * b / 65536          real product, Q16 out
qdiv(a, b) = a * 65536 / b           real quotient, Q16 out
q32(a, b)  = a * 2^32 / b            quotient out of the Q32 scale
```

This example lost **two** defects to that trap, in two different disguises, and
both are commented where they were:

- `flock.steer` normalizing a Q16 vector: `(sx * Q16) / l`, not `sx / l`.
  Written the second way, a 3-4-5 triangle's unit vector is `(0, 0)` and the
  steering force is silently nothing.
- `flock.seed_flock` the same way, which is why the first version of the table
  printed `mean |v| 0.00` for the whole flock: every bird was seeded stationary.

`--check` group 1 pins both shapes, and `inject.sh` #5 injects the trap live.

### The store, and why there is no allocation in a loop

Six fixed-size `[long; 512]` arrays inside one `Flock` record, allocated once by
`flock.blank`. The Y heap is an arena and nothing is freed, so anything the hot
loop builds is permanent: a record literal in the pair loop would be 48 bytes a
**pair**, and 512 boids is 130 816 pairs a step — 6 MiB a step, and the 3.5 GiB
cap after about 600 frames. So the accumulator, the steering result, the
normalized direction, the pair tally and the `mask_name()` string are all
module-level, and every temporary in `step()` is a `long`.

Measured: **0 bytes over the frame loop**, at both 120 and 512 boids, and **0
bytes over 361 live frames at 60 fps** with 300 boids (`--stats`, checked
through a pty by `pty_check.py`).

The one leak that did ship is worth recording, because `--stats` is what found
it: `status()` used to call `flock.mask_name()` every frame, and that function
builds a string by concatenation. 168 bytes a frame, 40 KB over 241 frames —
invisible for a minute and fatal for an hour. The mask only changes on a key
press, so the name is built once and refreshed there.

### Jacobi, not Gauss-Seidel

`step()` makes two passes over the boids: the first computes every boid's
steering from the state as it was at the top of the step, so a boid's neighbours
cannot see it move; the second integrates all of them in place. One interleaved
pass would be cheaper — one loop, no `ax`/`ay` arrays — but it would make boid 3
see boid 2's new velocity, which is order-dependent and much harder to argue
about when a test asserts a hand-computed result.

### The torus

The world wraps, so a flock has no edges to pile up against. `wrap_delta()`
shortens a difference to the shortest signed way round, and `wrap_pos()` brings
a position back into `[0, span)`. One correction in `wrap_pos` is always
enough: `set_limits()` caps the max speed at a quarter of the smaller side, so a
step can never travel half the world.

This is visible in the check, not just in the code. After one separation step
the pair in group 3 is 20.99998 units apart on a 32-unit world, and the distance
the flock *sees* is 11.00002 — the other way round. Removing the wrap
(`inject.sh` #9) changes exactly that assertion and nothing else.

### The `str +=` audit, done rather than eyeballed

`../../refs/ycc.ref -S boids.y > boids.s`, then count two symbols per function:
`call y_str_app` is the in-place amortised append (a **discarded** position) and
`call y_str_cat` is the exact-size copy (a **value-used** position). A function
with `cat > 0` inside a loop is the quadratic.

Result over all 199 user functions:

- **30 of them are on the hot path** — `flock.isqrt`, `dist`, `unit`,
  `wrap_delta`, `wrap_pos`, `steer`, `accumulate`, `rule_sum`, `step`,
  `heading`, `mean_speed`, `mean_order`, `span_x`, `in_bounds`, `digest`,
  `diff`, `seed_flock`, every `report.rb_*`, `report.frame_text`,
  `report.occupied`, `report.row`, `run_live`. **29 of the 30 are `app=0 cat=0`.**
- the 30th, `run_live`, has `cat=1` and it is 18 lines into the function: the
  one-shot `eputs("boids: use --no-tty --frames N ...")` on the
  stdin-is-not-a-terminal path, before the loop.
- the 29 functions with `cat > 0` overall are all **build a string once and
  return it**: `main` (49, the flag-validation messages), `report.run` (38, the
  header and summary blocks), `check.t_signs` (29), `stats_block` (22, printed
  once on exit), `flock.mask_name` (5 — and it is no longer called from the
  render loop, which is where the 168 B/frame leak came from), `report.field`,
  `report.fixed`, `report.hexstr`, and `check`'s own `say`/`eq`/`ne`/`nonzero`,
  which allocate by design because a diagnostic is not a frame.

So the render loop and the per-frame table contain **no** value-used string
concatenation at all, and the per-frame cost is confirmed independently by
`heap_used()` moving 0 bytes over 200 headless steps and 361 live frames.

### The render loop

The interactive path is the shape `tui`'s header asks for: raw mode, alt
screen, the crash watchdog, and **one** `restore_all_exit` at the bottom that
every early exit routes through. `pty_check.py` asserts on every path — the quit
key, `Escape`, `Ctrl-C`, a resize, and an error path that never enters the alt
screen — that the alt screen is left, the cursor is shown and termios is restored.

The keyboard is polled with **`read_key_timeout(0)`** and `tui`'s pacer owns
the deadline. `read_key_timeout(ms)` spends its wait in the terminal's `VTIME`,
which counts **deciseconds**, so any non-zero request rounds *up* to the next
100 ms: `read_key_timeout(20)` is a 100 ms block, which at a 33 ms frame period
makes every frame late by more than a whole period, the pacer drops it, and
because a dropped frame still costs its 100 ms the schedule never recovers. The
symptom is ~0.6 fps with the frame counter stuck on 1, which reads as "the
animation is slow" rather than as a bug. `pty_check.py` groups 2 and 3 are
there to make that symptom loud if it ever comes back.

---

## Throughput and allocation

`--stats` on this machine, one core, under the 3.5 GiB cap:

| configuration | wall | per step | pairs/step | pair-steps/s | roots/s | ns per root |
|---|---|---|---|---|---|---|
| 120 boids, 100×40, 200 steps | 49 ms | 246 µs | 2 208 | 8 955 042 | 10 415 103 | 96 |
| 512 boids, 100×40, 100 steps | 329 ms | 3 293 µs | 18 518 | 5 623 170 | 6 089 591 | 164 |

A *root* is one `isqrt` call. Each neighbour pair forms one squared distance and
each rule force takes one root of that force, so a step takes
`pairs + 3 * boids` roots. The two rows are the same code on different store
sizes; the per-root cost rises because the six 512-long arrays (24 KiB) stop
fitting the L1 the way a 120-bird flock's working set does.

Heap, `heap_used()` either side of the frame loop:

```
120 boids, 200 steps:   360384 -> 360384 B   (0 over 200 steps)
512 boids, 100 steps:   360384 -> 360384 B   (0 over 100 steps)
live view, 300 boids, 361 frames at 60 fps:  0 B over the loop
```

The live view's rate is bounded by the pacer, not by the simulation: 46 frames in
1.5 s at a 30 fps cap, and 361 frames in 6 s at 60 fps, both measured through a
pty.

---

## Determinism

- **Same seed, same state.** `flock.digest()` is a 46-bit checksum over every
  position and velocity; `--check` group 7 asserts two independent 250-frame
  runs differ in **zero** boids, and then — the part that stops it being
  vacuous — that two runs of *different* seeds differ in nearly all of them,
  and that moving one boid by one Q16 unit changes the digest.
- **The generator.** Lehmer's MINSTD (`state = state * 48271 mod 2^31-1`),
  chosen because `state * 48271` is under 1.03e14 and no multiplication in it
  can overflow — there is no masking to get wrong. `rng_below()` folds in a
  second draw before the modulo, because MINSTD's low bits are its weakest and a
  flock that starts in stripes looks like a flock that *started* striped.
  Group 9 asserts 400 draws over 1000 values are mostly distinct, span most of
  the range, and have a mean near 500.
- **`--seed 1` is the default** and there is no unseeded randomness anywhere.
- **`EXPECTED` reproduces byte for byte**, twice, under the pinned compiler.
  `sh capture.sh && sh capture.sh && git diff --exit-code` is the check.

---

## The vendored toolkit — frozen, copied, never edited

Copied byte-identical with `cp` from `examples/_toolkit/` and **not modified**:

| file | sha256 |
|---|---|
| `fx.y`   | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` |

Everything this example needs of its own is in a file beside them:
`flock.y`, `report.y`, `check.y`. `gate.py` item 1 compiles all nine `.y` files
in the folder with zero warnings, which includes the five vendored ones
unmodified.

---

## Compiler workarounds in this folder

Nothing was filed against the compiler: everything below is a property of the
language that the code works around, and each is visible where it happens.

| what | where | why |
|---|---|---|
| `a / b` on two fixed-point values is their **ratio** | `flock.qmul`/`qdiv`/`q32`/`unit`/`steer`, checked in `--check` group 1 | a scaled quotient needs the 65536 in the numerator. Cost this example two real defects; `--check` and `inject.sh` #5 now pin it |
| `tui.size()` builds a **record literal** per call (~40 B) | `boids.y`'s own `winsize()` | polling it once a frame leaks 40 B a frame. The frozen `tui` is not edited; the four lines it would take to fix it upstream are written out instead, into a module-level `[byte; 64]`, returning one packed `long` so the allocation count stays at zero |
| a `str` built by concatenation allocates | `boids.y`'s `status()` takes the rule names as a parameter | `mask_name()` is three concatenations. Called from the render loop it leaked 168 B a frame; found by `--stats`, and `pty_check.py` group 8 asserts the heap stays put over 241 live frames |
| a literal array or record inside a loop body allocates 64/40 B an iteration | `flock.y`'s `Flock`, `report.y`'s buffers, `check.y`'s `TALLY`/`HD_A`/`HD_B` | the heap is an arena. All the scratch is module-level and sized by a literal |
| `[0; n]` needs an integer **literal** size | `report.y`'s `GRID` | so the text grid is sized for the largest world the store allows (256×129 = 33024) rather than from a variable at run time |
| no `break`, no `continue` | `check.y`'s frame loops use counters | early exit is a guard flag with an explicit terminal assignment; continue is a positive condition around the body |
| `main()`'s return value is not the exit status | `boids.y`'s `def main() -> long` + `exit(main())` | `main();` discards it and exits 0, so an error path that "returns 1" looks successful. Every path out of `main` **returns** a status and none of them calls `exit()` — a body ending in `exit()` is void, so `-> long` on it is a compile error |
| a `def` IS a first-class value, typed `(parameter type) -> return type` | not used here | worth knowing: `let f: [(long) -> long] = [double_it];` works, so a dispatch table needs no closure |
| `>>>` is a **logical** shift | `flock.isqrt` uses `>>` | every value in the digit recurrence is non-negative, but `>>` is used on purpose throughout: a logical shift on a negative intermediate is a silent wrong number, not a trap |
| runtime traps print to **stdout** | `report.y` bounds its own writes; `main()` validates every flag | a trap would silently corrupt `EXPECTED` instead of announcing itself. Every error path prints a message to stderr and exits non-zero — verified for `--size`, `--frames`, `--dump`, `--fps`, `--seed`, `--boids`, `--rules`, `--color` and the three weights, with and without a terminal |
| `wrap_pos` needs its bounds checked by the caller | `report.frame_text` | an out-of-bounds store is a trap, and a trap goes to stdout |

### Four defects this example shipped and fixed, recorded because they were invisible

All four are the kind that pass every gate item, and all four are now covered by
something that runs:

1. **`report.frame_text` indexed the text grid with a stride of `cols` while
   putting each row's newline at `y*cols + cols` — which is row *y+1*'s first
   cell.** The next iteration's fill overwrote it with a `.`, so the whole world
   printed as one enormous line with a single newline at the end. `--no-tty
   --frames 1` output is the only place it showed; the golden would have
   recorded it faithfully forever. Fixed by indexing everything with `stride`,
   and `frame_text` is now covered by `--check` groups 5 and 8 (the wrap
   assertions read positions the same way).
2. **`check.run()` ended with `if (FAILED == 0) { …; 0 }; …; 1`.** An `if` arm's
   value is its last statement, so the `0` was the *block's* value, the block was
   discarded, and the function fell through to the trailing `1`: the check printed
   "0 failed" and **exited 1**, and `gate.py` item 8 reported that as a failure of
   the check. `inject.sh` #18 and #19 now pin the exit status in both directions.
3. **`--color` was validated on the live path only**, so
   `--no-tty --color nonsense` printed a perfectly normal report and exited 0:
   the headless path returned before the colour was ever read, and the headless
   path is the one compared byte for byte. Moved up with the other flags.
4. **`--frames` used −1 as its "not given" sentinel**, so `--frames=-1` was
   indistinguishable from not giving it: the default 200-frame report, exit 0. A
   number the user typed must never equal a number they did not, so "was it
   given" is now `args.has("frames")` and the value is checked separately.

`errpaths.sh` sweeps all 24 of them — `--size` (six shapes), the four numeric
flags, the three weights, `--boids`, `--view`, `--sep`, `--rules`, `--color`, an
unknown flag and a stray operand — and requires of each: exit code 1, no
`runtime error:` anywhere, and a first line that says what was wrong. It found
defects 3 and 4, both of which the gate would have passed.

---

## Files

| file | what |
|---|---|
| `boids.y` | the driver: flags, validation, the live view, `winsize()`, the status line, the palette |
| `flock.y` | the simulation: store, neighbour loop, the three rules, steering, the clamp, the torus, the generator |
| `report.y` | the headless report: the fixed-byte writer, the per-frame table, the frame as text |
| `check.y` | the property check — 188 assertions in 9 groups |
| `oracle.py` | an independent integer model of `flock.y`'s arithmetic; run by hand to confirm the constants in `check.y` |
| `inject.sh` | 19 defect injections; every one must make `--check` fail |
| `pty_check.py` | nine real-pty sessions against the live view |
| `errpaths.sh` | sweeps all 24 flag-error paths: exit 1, a message, no trap |
| `capture.sh` | regenerates `EXPECTED` and `golden/` |
| `gate.conf` | `build=`, `run=`, `check=` for `examples/gate.py` |
| `EXPECTED` | the golden for the `run=` line, 8 677 bytes |
| `golden/` | five more goldens, including one per rule |

---

## The gate

```
python3 ../gate.py boids
```

```
[PASS] 0 compiler pin present
[PASS] 1 compile zero warnings  9 file(s) clean
[PASS] 2 golden output  8677B identical over 2 runs
[PASS] 3 no runtime trap
[PASS] 4 inside memory cap
[PASS] 5 self-contained  no cross-folder import or embed
[PASS] 6 README complete
[PASS] 7 filing pointers resolve
[PASS] 8 example's own property check  188 assertions passed, 0 failed
=== boids: 9/9 passed ===
```
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
