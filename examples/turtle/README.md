# turtle — a turtle-graphics interpreter, in a terminal

An interpreter for a small turtle language — `forward`, `back`, `left`,
`right`, `setheading`, `pen up`/`pen down`, `colour`, `dot`, `jump`,
`repeat N [ … ]` — driving an integer turtle with a position and a heading over
a terminal framebuffer.  It **draws** programs: eight ship with it, and
`--script FILE` reads one of your own.  It renders them two ways: a
deterministic headless path that writes a frame table and a text picture, and an
interactive path you step through **one command at a time** so the drawing
appears as the turtle walks.

```
build:  cd examples/turtle && ../../refs/ycc.ref turtle.y -o turtle
run:    ./turtle                                    interactive: . steps, a auto-runs
        ./turtle --no-tty --frames 3 --prog koch --size 60x26
        ./turtle --script programs/square.turtle --no-tty --frames 2
        ./turtle --list                             the eight built-ins, as source
        ./turtle --check 4000                       the property check
gate:   sh gate.sh                                  every gate item in one place
```

## What is worth looking at

**The heading arithmetic.**  The heading is a count of **milli-degrees** and the
wrap is `h - 360000*(h/360000)` with a sign fix-up — integer arithmetic on an
integer constant, so there is no cancellation error and no drift of any kind.
`left 90` four times is `+360000`, `k = 1`, `r = 0`, and the heading is back
where it started **bit for bit**.  A heading that goes *negative* is the case an
off-by-one hides in: `right 90` from 0 must be exactly `270000`, and a wrap that
forgets the sign fix-up leaves it at `-1`.  The picture still comes out right in
both cases, which is exactly why a golden file cannot see it and this folder's
property check asserts it directly (`W1`, `W4`).

**The polygon closure**, and why it is exact to the unit rather than nearly.
`--prog square` is four 100-unit moves with a quarter turn between them, and it
ends at (0, 0) facing exactly 0 — and so do a triangle, a hexagon, a pentagon
and an octagon.  The pentagon is the interesting one, because `cos 72°` is
irrational: its closure is a consequence of the *rounding*, not of the
trigonometry.  The arithmetic is in [why the polygons close](#why-the-polygons-close)
below, and the tables were derived **outside** this program, with a different
trigonometry, and pasted in as literals.

**`--check 4000`** — 35 assertions about the interpreter's behaviour, with no
reference file involved.  Its output is in [the property check](#the-property-check).

## The language

| command | meaning |
|---|---|
| `forward n` (`fd`, `f`) | move `n` units, drawing if the pen is down |
| `back n` (`backward`, `bk`, `b`) | move back `n` units — a *negative* forward |
| `left deg` (`lt`, `l`) | anticlockwise |
| `right deg` (`rt`, `r`) | clockwise |
| `setheading deg` (`heading`) | absolute heading |
| `pen up` / `pen down` | lift and lower the pen |
| `colour NAME` (`color`) | black red green yellow blue magenta cyan white orange grey brown lime pink violet silver gold |
| `dot` | one dot, no movement |
| `jump dx dy` | move **without drawing**, pen up or down — a stride |
| `repeat N [ … ]` | N passes; nests 12 deep |
| `# …` | a comment to end of line; `;` also separates |

World coordinates are integers with **y up**; a turn is in integer degrees; a
heading that would leave the circle wraps instead of growing without bound.  A
program is a flat token stream and `repeat` is the only block form.

**The sign convention, pinned.**  From the origin, `forward 100` then `right 90`
then `forward 100` ends at **(100, −100)**: `right` is clockwise, so the turtle
turns down the screen.  `left 90` then `forward 10` ends at **(0, +10)**: north
on screen.  A `right` that added to the heading instead of subtracting would
draw a perfect mirror image and no golden file could tell — so the check asserts
it (`M1`, from a table of eight micro-programs).

## The interactive path

It starts **held**, not running: this is a turtle, and the interesting part is
watching where it goes.

| key | |
|---|---|
| `.` space enter | one command, then redraw |
| `a` | hand the stepping to the frame pacer (and back) |
| `c` | clear and start the program over |
| `h` | show or hide the turtle cursor |
| `n` | next built-in program |
| `+` `−` | the frame rate |
| `q` esc | quit |

The render-loop discipline the closed waves converged on, and why each piece is
here: the frame deadline belongs to `tui`'s pacer and the keyboard is polled
with **`term.read_key_timeout(0)`**, because `VTIME` counts deciseconds so any
non-zero millisecond count rounds up to the next 100 ms — a 1..99 poll would put
every frame a period late and report ~0.6 fps with a stuck frame counter, which
reads as "the animation is slow" rather than as a bug.  The window size is
polled with a **hand-written `poll_winsize()`** into a module-level buffer on
every fourth frame (`term.size()` returns a fresh ~40-byte record per call, which
would leak in a poll), and a resize **redraws the program from the start**,
because the two projection shifts have changed and every pixel on screen is now
in the wrong place.  The status line is assembled into `sink`'s module-level byte
buffer and blitted a cell at a time — not `fb.text` with a `str`, which would
allocate every frame.

There is no `break` and no `continue` in this language (both are undefined
names), so every early exit in this folder is a guard flag with an explicit
terminal assignment: `headless()`'s inner loop, `render()`'s draw loop, the
interactive stepping loop, and `case_pen`'s non-vacuity checks.

## The headless path, and what the golden contains

`--no-tty --frames N` steps exactly N frames with no clock, no terminal and no
randomness, prints a per-frame table and the last frame as text, and exits 0.
That is `gate.conf`'s `run=` line, and `EXPECTED` holds its stdout.

Each frame runs `ceil(steps / frames)` commands, where **`steps` is how many
commands the program EXECUTES, not how many opcodes it has** — a repeat body runs
once per pass.  Dividing by the opcode count was the first version's bug, and it
was invisible: with `--frames 3` a program containing a `repeat` finished in
frame 3 having drawn two thirds of itself, deterministically.  With the execution
count, **the last frame is always the finished drawing**, whatever N was.

The per-frame line carries the bytes fb emitted, the bytes it captured, the
commands run, the cells inked, the turtle's position and heading, the pen, the
colour, and an FNV-1a digest over every cell's codepoint *and both of its
colours*.  The digest is the part that is evidence: `golden/` holds fourteen text
frames (`python3 snap.py` regenerates them, `snap.py --check` verifies them), and
a diff of those pictures says what moved, where a digest only says that
something did.

## Why the polygons close

The turtle's position is in integer units and its heading is in milli-degrees, so
the whole interpreter is integer arithmetic — there is no `float`→`long` in Y and
no math functions either (`ORCHESTRATOR.md` §2.4), so the trigonometry is
`fx.sin`/`fx.cos` in Q30 and nothing else.  A step of `n` units at heading `h`
advances by

```
dx = round_half_away(n · cos h)        dy = round_half_away(n · sin h)
```

rounded to **whole units**, and that rounding is the whole of the closure story.
Derived outside this program (Python, libm, `floor(v+0.5)` — half away from zero,
which is `fx.round`'s rule):

| sides | turn | vertices, hand-computed |
|---|---|---|
| 4 | 90 | (100,0) (100,−100) (0,−100) (0,0) |
| 3 | 120 | (100,0) (50,−87) (0,0) |
| 6 | 60 | (100,0) (150,−87) (100,−174) (0,−174) (−50,−87) (0,0) |
| 5 | 72 | (100,0) (131,−95) (50,−154) (−31,−95) (0,0) |
| 8 | 45 | (100,0) (171,−71) (171,−171) (100,−242) (0,−242) (−71,−171) (−71,−71) (0,0) |

Every one ends at exactly (0,0) facing exactly 0.  For the square, the triangle
and the hexagon each step is an exact half or an exact `n√3/2` that rounds
cleanly; the pentagon is the one that matters, because it closes **only** because
`round(100·cos 72°) = 31` and `round(100·sin 72°) = 95` happen to pair up:
100 + 31 − 81 − 81 + 31 = 0 in x, and 0 + 95 + 59 − 59 − 95 = 0 in y.  Without
the rounding to whole units that figure would be about 0.3 units out.

**The tables are only trustworthy because the rounding cannot be steered by
fx's error.**  That is not a hope, it is a measurement, and the check makes it:
for every step in those tables it computes the distance from the pre-rounding
product to the nearest **rounding tie** and requires it to be at least 10⁶ Q30
units — a thousandth of a unit — against fx's actual error.  The measured minimum
margin is **106 140 024 Q30 units (0.099 units)**, two orders of magnitude
clear.  Any trig error smaller than that cannot change a single rounded integer,
so a table computed with a *different* trigonometry agrees with this one exactly.
The check asserts this and prints the margin (`S2`).

It also measures what fx's trigonometry is *not*, rather than assuming:
`step(n, h+180°) = −step(n, h)` is **not** exactly true.  At a 100-unit step,
**24 of 360000** headings disagree, each by exactly one unit (`S3`).  What makes
closure work is that the disagreement is smaller than the rounding can absorb,
and the check asserts the bound (≤ 1 unit, everywhere, over the sweep) rather
than the exactness it would have liked.  The headings the polygon tables use are
asserted **exactly**.

## The property check

`./turtle --check N` runs 35 assertions and exits with the number of failures.
**No reference file is involved anywhere in it.**  `EXPECTED` holds the
determinism; this holds the geometry.

```
$ ./turtle --check 4000
turtle: property check -- no reference file is involved
turtle: sample headings per sweep = 4000, surface 60x26
W1  wrap_deg exact on ten hand-computed values              ok
W2  wrap_deg in range and drift-free over 360000 headings   ok  headings=4000
W3  four left 90 through the interpreter return the start   ok
W4  negative headings wrap right: right 90 = 270000, y = -10ok
W5  left 1 and right 1, a whole turn each, return the start ok  steps=360000
S1  step(n, 0) = (n, 0) and step(0, h) = (0, 0), exactly    ok
S2  every polygon step is far from a rounding boundary      ok  min margin q30=106140024
S3  antipodal to within 1 unit over the whole circle        ok  disagree=24
S4  |step(100, h)|^2 within 200 of 10000 over the circle    ok  worst d=132
P1  closes on the unit and returns to heading 0             ok  sides=4
P2  closes on the unit and returns to heading 0             ok  sides=3
P3  closes on the unit and returns to heading 0             ok  sides=6
P4  closes on the unit and returns to heading 0             ok  sides=5
P5  closes on the unit and returns to heading 0             ok  sides=8
M1  eight micro-programs match the tabulated path           ok
Q1  repeat parses to the expected opcode stream             ok
Q2  f/r/b are forward/right/back; # and ; are ignored       ok
Q3  repeat N runs its body exactly N times, for six counts  ok
Q4  nested repeats: 2x3 forward 10 = 60, repeat 0 draws nothingok
Q5  fourteen malformed programs refused, with a message     ok  refused=14
Q6  all sixteen colour names resolve to their own index     ok  0
U0  a cleared surface is entirely blank                     ok
U1  pen up moves leave every cell untouched                 ok  cells inked=0
U2  the same two moves with the pen down DO draw            ok  cells inked=25
U3  a pen-up segment's frame is byte-identical to skipping it ok  cells a/b=26
U4  a dot is 1 cell with the pen down, 0 with it up         ok
U5  the digest watches the codepoint, the fg and the bg     ok
C1  the frame flushes to a non-empty, repeatable capture    ok  bytes=2191
C2  one perturbed cell changes the checksum, back again restores it ok  bytes=2191
V1  a 12-unit step inks exactly cells (13,10)..(13,22)     ok  cells=13
V2  the view is fitted per axis: shift 1/3 for the unit square ok  shift x=1
V3  the bounding box includes the origin the turtle started at ok
V4  a path that only goes +x still has the origin in its box ok
Z1  heap delta over 400 drawn frames                        ok  delta=0
D1  the same program renders to the same digest, a different one not ok

assertions 35  passed 35  failed 0
check: PASS
```

`--check 360000` makes every trigonometric sweep exhaustive and takes **0.16 s**.

### What each group is for

* **W — the wrap.** Ten hand-computed values (including `10¹² → 280000` and
  `−1 → 359999`); the range invariant and *drift-freedom* over a sweep (a heading
  of `h + 100000 whole turns` must fold to where `h` folds to, which a wrap that
  only ever saw small headings would pass); four `left 90` **through the
  interpreter** at six starting headings; the negative half; and a whole turn one
  degree at a time, 360 000 wraps, which is the assertion a wrap that drifts by a
  unit every few thousand turns fails.
* **S — the step vector.** `step(n,0) = (n,0)` and `step(0,h) = 0` are *exact*
  integer identities; the rounding-tie margin of §above; the antipodality bound,
  with the number of disagreeing headings printed rather than assumed; and the
  step's length, so a trig that returned zero cannot pass the antipodality test
  and collapse every polygon to a point.
* **P — closure.** Five polygons, **vertex by vertex** against the tables above,
  each also asserting its segment count, its final (0,0) and its final heading 0.
* **M — micro-programs.** Eight programs of two to five commands, tabulated
  above, with every vertex *and* the final position *and* the final heading.
* **Q — parsing.** The exact opcode stream for a `repeat` against a hand-written
  triple table (opcode, a, b) — including the skip target that makes `repeat 0`
  work; the aliases; `repeat N` running its body exactly N times for six counts;
  nesting; fourteen malformed programs each refused with a message, and the
  *flavour* of the diagnostic (a parser that skipped an unknown word and then
  complained about the number after it also returns −1 with a line number, which
  is how mutation 14 was caught); all sixteen colour names against their indices.
* **U — the pen.** A pen-up move leaves **every cell untouched**; the same moves
  with the pen down really do draw — asserted *before* anything is compared, so
  "the pen-up frame equals the blank frame" cannot be the trivial truth about two
  frames that are both empty; and the sharp one: under **one forced view**, the
  frame left by `pen down forward 12  pen up forward 12  pen down forward 12` is
  **byte-identical** (whole-surface digest, both colours) to the frame of
  `forward 12  jump 12 0  forward 12`, which walks the identical path with no
  pen-up in it — while a program that *does* draw the middle segment inks more and
  digests differently.
* **V — absolute geometry.** Everything above compares the interpreter against
  itself, which is blind to a defect that shifts every pixel the same way.  V1
  pins the projection to **hand-computed cells**: a 12-unit step along +x inks
  cells (13,10)…(13,22) and *nothing else* — thirteen cells, because a line
  plots both endpoints.  V2 pins the per-axis fit (for the unit square on 60×26
  the shifts are 1 and 3, hand-derivable from the fitting rule).  V3/V4 pin the
  bounding box, including the case a path that only ever goes +x exercises.
* **C — the capture round trip.** The flushed byte count is asserted **non-zero
  first** (2191 bytes), then two flushes of the same surface agree, then
  perturbing **one** cell changes the checksum, then putting it back restores it,
  and a blank surface does not share the checksum.  A checksum compared without
  first proving it is over a non-empty stream is the vacuous pass this campaign
  has produced twice.
* **Z — allocation.** The heap delta over 400 drawn frames is 0.
* **D — determinism.** The same program rendered twice gives the same digest; a
  different one does not.

### Defect injection

`python3 mutate.py` applies each mutation below to a copy of the sources,
rebuilds with the pinned compiler, and requires the check to **fail**.  The
harness checks that every pattern occurs exactly once before building, so a
mutation that quietly stops applying is a loud failure — the shape of mistake this
harness exists to prevent in itself, and it made one: the first run staged the
sources *after* writing the mutation, copied the pristine file over it, and
reported **25 of 25 missed** with the message "the check reported success", which
was true of a build that had never been mutated.

**Result: 25 mutations, 24 caught, 1 declared blind spot, 0 unexplained misses.**

| # | mutation | caught by |
|---|---|---|
| 1 | `right` turns the wrong way | M1, W4, P1–P5 |
| 2 | the wrap loses one millidegree | W1 (value 0: 359999 ≠ 0) |
| 3 | the wrap loses the negative half | W1 (value 4: −1 ≠ 359999) |
| 4 | the wrap divides by 359999 | W1 (value 7: −2240000 ≠ 280000) |
| 5 | the step rounds toward zero, not away | W4, P1–P5 |
| 6 | sin and cos swapped | W4, S1, S4 |
| 7 | the heading lifted into Q30 twice | W4 |
| 8 | `back` moves forward | M1 (`forward 10 back 4`) |
| 9 | `pen up` does not lift the pen | U1 (ink=25 where 0 is required) |
| 10 | `repeat N` runs its body N+1 times | Q3 |
| 11 | the loop stack pops on every pass | Q3 |
| 12 | `repeat 0` runs its body once | Q3 |
| 13 | `]` patches the wrong opcode's skip target | Q1 |
| 14 | an unknown command is accepted | Q5 (the diagnostic's flavour) |
| 15 | a comment swallows the rest of the file | Q2 |
| 16 | a step's distance is off by one unit | W4, P1–P5 |
| 17 | the bounding box forgets the start | **V4** |
| 18 | a drawn cell is written at row+1 | **V1** |
| 19 | Bresenham drops its last cell | **V1** |
| 20 | the view fitted with one shared shift | **V2** (shift 1/1) |
| 21 | a stack buffer allocated inside the line loop | Z1 (delta 832) |
| 22 | *the check's own sweep samples 1 heading in 7* | **nothing — declared blind** |
| 23 | the headless frame loop allocates per frame | the gate's heap-delta line (104) |
| 24 | the digest ignores the foreground colour | U5 (fg=0, i.e. no change) |
| 25 | a colour name resolves to the wrong index | Q6 |

The five in bold are mutations that **only** the later additions caught, and each
of them had already been run and reported as a miss: V4 because `track()` grows
the box straight back to include the origin for every polygon, V1 because every
earlier ink assertion was a comparison against another count rather than against
absolute cells, V2 because the first version of mutation 20 was itself
*equivalent* (it added a redundant `SHY = 0` and removed another one, and the
harness correctly refused to call that a pass), U5 because comparing two
programmes in two colours does not test the colour channel — the glyph is chosen
by the colour, so a digest watching only the glyph still sees them differ — and
Q5 because "refused with a message" is satisfied by a parser that refuses for the
wrong reason.

**Mutation 22 is the battery's boundary and is listed, not dropped.**  It weakens
the *check* rather than the program: no assertion can notice that an assertion
samples less.  It is not harmless, and the evidence is measured rather than
argued — the check prints its own coverage, and W2 reports `headings=4000` with
the correct stride against `headings=57` with this one.  A battery that could
catch this would have to check itself, which means a second independent oracle
over the same assertions.

**What else this battery cannot catch**, beyond mutation 22:

* **Anything about the *view* that does not move a pixel count or a shift.**
  Where on screen a specific picture sits is a design decision, not a truth, and
  the assertions only reach it through V1/V2/V3/V4.
* **The interactive path's timing.** Keys, pacing and the redraw are checked
  through a real pty (`pty_check.py` — alt screen in and out, the terminal
  restored, and every keypress provably making the program emit more bytes), but
  nothing measures whether 15 fps is 15 fps.
* **Anything a golden already covers.** Mutation 23's shape — an allocation in
  `turtle.y`'s own frame loop — cannot be reached from `--check` at all, because
  `check.y` is imported *by* `turtle.y` and calling back would be circular.  It
  is caught by the gate's own heap-delta line over `--frames 200`, and the
  harness runs that instead (`KIND = "heap"`), so the battery honestly includes
  the allocation assertion rather than claiming `--check` covers it.

## Performance and allocation

Measured on the pinned compiler, under the campaign's 3.5 GiB cap, wall clock on
a shared machine:

```
$ ./turtle --no-tty --frames 200  --prog koch   --size 60x26 --time
turtle: 200 frames in 2247 us = 2 ms, 33822 commands a second
turtle: 2953 bytes emitted, 92 cells inked, heap before=2028016 after=2028016 delta=0

$ ./turtle --no-tty --frames 2000 --prog spiral --size 120x40 --time
turtle: 2000 frames in 64312 us = 64 ms, 497 commands a second
turtle: 5858 bytes emitted, 73 cells inked, heap before=2027120 after=2027120 delta=0

$ time ./turtle --check 360000        # the sweeps made exhaustive
0.16 s

# the interactive path, through a pty, `a` held down (this is where hud runs):
frames=114 heap 2026536 -> 2026696 delta=160
frames=264 heap 2026536 -> 2026696 delta=160      <- the same 160 bytes
```

* **Zero allocation on the frame path, measured not asserted**: the heap delta is
  0 over 200 frames at 60×26 and over 2000 at 120×40, and `Z1` asserts it over
  400 drawn frames.  The whole interpreter's state is module-level fixed arrays:
  the opcode stream, the loop stack, the token store, the repeat stack, the
  trace.  The one allocation the program makes outside them is `fb.new`'s 1.5 MiB
  surface, once, at startup.
* **Two trig calls per move and none per turn.**  A move asks `fx.cos` and
  `fx.sin` once each and rounds the result to whole units; a turn is `h +
  a` followed by `wrap_deg`, which is integer arithmetic and no trigonometry at
  all.  That is the whole reason the heading arithmetic can be exact.
* **No quadratic `str +=`, audited rather than eyeballed.**  `call y_str_app` is
  the in-place amortised append (a *discarded* position) and `call y_str_cat` the
  exact-size copy (a *value-used* position), and a `cat` inside a loop is the
  defect.  Built from the real entry point —
  `../../refs/ycc.ref -S turtle.y > /tmp/t.s` — and attributed to the enclosing
  function:

  | `y_str_cat` | n | where |
  |---|---|---|
  | `turtle.hud` | 10 | once per frame, interactive only |
  | `tlang.compile` | 6 | once per program, and on the error paths only |
  | `tlang.num_at` | 2 | once per malformed argument |
  | `check.case_colours` | 1 | 16 times in total, inside `--check` |
  | `args.usage` / `ar_long` / `ar_short` / `ar_take` / `ar_left` / `ar_fail` | 31 | vendored, not on any frame path |
  | `fb.y_str_pad_right` | 1 | vendored |

  `y_str_app` is 15, of which 6 are mine and 9 are `args`'s.  So: no `cat`
  inside a loop on any per-frame path, and the one per-frame function that has
  ten of them (`hud`) demonstrably does not allocate — the interactive heap delta
  is **exactly 160 bytes for 114 frames and exactly 160 bytes for 264 frames**
  (measured through a pty with `a` held down), so it is the fixed cost of the
  final `eputs` report and not a leak.  The same `+` fix does not apply to a
  load-bearing value-used append: adding the `;` there is a compile error
  (`'f' body: expected str, got void`), which is how you find the ones you must
  not touch.
* **Compile time**: the whole folder — five program files, five vendored toolkit
  files, 10 sources in all — builds in **0.056 s**.

## Files

| | |
|---|---|
| `turtle.y` | the driver: options, the two frame loops, the status line, the script reader |
| `tlang.y` | the whole language — tokeniser, compiler to opcodes, executor, colour table, the eight built-in programs.  Imports `fx` and nothing else |
| `scene.y` | the whole rasteriser: the two-shift projection, the per-axis fit, Bresenham, the turtle cursor, `INK` |
| `sink.y` | the deterministic byte sink: every byte this program prints goes through one module-level buffer and one `write(2)` |
| `check.y` | the property check, and the oracle behind it |
| `programs/*.turtle` | fixtures: the closure demos as files, a file with no trailing newline, an empty program, and six malformed ones for the error paths |
| `gate.conf`, `EXPECTED`, `gate.sh` | the gate: the deterministic invocation, its output, and every gate item in one script |
| `snap.py` | regenerates `EXPECTED` and the fourteen `golden/*.txt`; `--check` verifies them |
| `pty_check.py` | the interactive path through a real pty (no tmux on this machine) |
| `mutate.py` | the 25 defect injections |

## Compiler notes, and what they cost

Everything below is a property of the language, not a defect in it.  No compiler
bug was found while building this example, and nothing is filed in
`examples/BUGS.md` or `examples/SUGGESTIONS.md` on its account — these are
workarounds, and they are visible in the code.

* **`fx.mul` divides by 2³⁰; it does not scale up.**  `fx.mul(h, 18740)` with `h`
  a *count* of milli-degrees is a ratio near zero, and the turtle spins on the
  spot drawing a tiny plausible scribble.  The heading has to be lifted into Q30
  with `fx.from_int` first (`tlang.rad`).  This is the campaign's fixed-point
  trap in Q30 form, and mutation 7 is its signature failure.
* **There is no `float`→`long` and no cast syntax**, so the whole-number bridge is
  `fx.to_int(fx.round(v))` — which is also what makes the rounding rule explicit
  and therefore what makes closure a property rather than an accident.
* **A kernel path must be NUL-terminated and a `str` is not.**  Every path goes
  into a byte buffer with an explicit NUL (`turtle.cpath`).  A string *literal*
  happens to work (measured), which is not a reason to rely on it: a path
  assembled from `argv` at run time has no such luck.  The one to try first is
  always the one that is accidentally right.
* **`print` appends a newline to every value**, so it cannot build one line out of
  parts and it is not used anywhere on the output path.
* **No `sort`, no `push`, no `map_get`/`map_set`** — and none needed: the opcode
  stream is three fixed arrays and `+=`/`*=` are the whole array interface.
* **No `break`, no `continue`** — see §the interactive path.
* **A fixed-size array is not a `[long]`**, so the tables passed to a function are
  declared `[long]`; five literals, allocated once at module scope, never in a
  loop.
* **There is no `break`-free way to leave a block early**, which is why every
  function that wants one returns a status and the caller decides.
* **A literal array or record inside a loop body allocates every iteration.**
  There are none: the digit scratch, the string builder's buffer, the token
  store, the opcode arrays and the trace are all module-level `let`s, and the
  status line is built into `sink`'s buffer.  Mutation 21 is the shape of the
  mistake and `Z1` the assertion that catches it.
* **`main()`'s return value is not the exit status**, so every exit path is
  `exit(...)`: `exit(check.run(n))` hands the failure count out, and the argument
  and script errors `exit(1)` after a message on stderr.

## The std units this uses

The toolkit modules come from std; `fx.y` is the only one still vendored
here, copied in byte-identical and never edited:

| file | sha256 |
|---|---|
| `fx.y` | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` |

Builds and runs with **`refs/ycc.ref` and nothing else**, whose sha256 at gate
time is

```
5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b
```

The pin moves during the campaign — it moved twice while this example was being
written (`e55fa8d0…`, then `9ce37629…`, then this one), and `EXPECTED`
reproduced byte for byte under every one of them, which is the point of keeping
the geometry in integers.  If it ever stops reproducing, re-run
`python3 snap.py` and record the new sha here rather than adjusting anything
else.
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
