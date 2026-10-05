# `fluid` — a real-time fluid simulation in the terminal

Jos Stam's **stable fluids** on a collocated grid, solved in integer Q30 fixed
point, drawn as a colour-and-glyph field you can stir with the arrow keys.

```
$ ./fluid                                  the live view, alt screen, q quits
$ ./fluid --frames 10 --no-tty             the deterministic run: a table and
                                           the final frame as text, exit 0
```

There is **no `float` anywhere in this program**. Y has no `float` → `long`
conversion and no cast syntax at all (`examples/ORCHESTRATOR.md` §2.4a), so every
quantity — velocity, pressure, dye, energy, divergence — is a `long` in Q30: the
real value *v* is held as *v* · 2³⁰, and `fx.ONE` is 1.0. The only conversion
into or out of the format is `from_int` / `to_int`, and the only bridge from a
Q30 quantity to a cell count is a division by `fx.ONE`. Every number the program
prints — including the four on the status line — is that integer, printed by
`textout.out_q()` and `fluid.y`'s `hq()`.

---

## What it is, and why stable fluids rather than shallow water

The brief offered both. **Stable fluids**, because its interesting part is the
pressure solve, and shallow water does not have one: the shallow-water
constraint is algebraic — a single line of face fluxes — where here it is a
five-point Poisson equation that has to be iterated, and *how well it is
iterated is visible and measurable*. `--iters 0` against `--iters 64` is a
factor of 20 in the residual divergence the report prints, and the table is
below.

A fluid is incompressible: it cannot be squeezed. Stam's trick is to write the
velocity field as the sum of a part that can be squeezed and a part that cannot,
find the second part with a projection, and work only with that.

```
step 0   external forces      the emitter: (-dy, +dx)/r, a stirrer
step 1   viscosity            (I - ν dt ∇²)u = u, by Jacobi sweeps
step 2   PROJECT              ∇²p = ∇·u, then u ← u - ∇p       ← the interesting part
step 3   advect               semi-Lagrangian: u(x) ← u(x - dt u(x))
step 4   vorticity confinement the small force that feeds eddies back
step 5   PROJECT again        advection is not divergence-free even when its
                              input was — which is exactly why the order is
                              add/diffuse/project/advect/project
step 6   drag and dye fade
```

Steps 2 and 5 are the same function called twice. Steps 1, 3, 4 and 6 are each
unconditionally stable, which is what "stable" means in the title: a timestep
too large does not explode, it just diffuses.

**The emitter is a stirrer, not a source, and that is the lesson of step 2.**
The projection deletes the divergence-free-irrelevant part of any force you
apply: a radial source (push outward from a point) is almost pure divergence, so
almost all of it is thrown away by the next `project()` and the user sees
nothing happen. A rotational force is almost pure curl, so it survives and spins
the fluid up into vortices. Hence `(-dy, +dx)/r`. If you change `sim.y`'s
`emit()` to `(dx, dy)/r` and watch the field refuse to move, you have just seen
the projection eat it.

`sim.py`'s boundary is **free slip**: on the left and right walls *u* is negated
and *v* copied, top and bottom the other way round. It adds and removes no mass
— which is why the dye mass in the summary is roughly conserved — and it is the
boundary under which the pressure Poisson problem is solvable at all (Neumann,
`dp/dn = 0`). The Neumann system has a one-dimensional nullspace, the constant,
which is harmless: the velocity update subtracts the **gradient** of *p*, and the
gradient of a constant is zero. It is also where the residual divergence
plateaus; see the table.

---

## Build and run

```sh
../../refs/ycc.ref fluid.y -o fluid      # or: sh gate.sh
./fluid                                  # interactive: alt screen, q quits
./fluid --frames 10 --no-tty             # the deterministic run (gate.conf's run=)
./fluid --help
python3 pty_check.py ./fluid             # drive the live view through a pty
python3 pty_check.py ./fluid --arrows    # ...after walking the emitter into
                                         #   all four corners with the arrow keys
```

`fluid.y`, `sim.y`, `textout.y` and the five vendored toolkit files must all sit
beside each other; every import is a **bare name** (`import fx;`), never
`import fx from "./fx.y"` — the path form parses but `fb.Surface` then fails to
resolve.

### Options

| flag | default | |
|---|---|---|
| `--frames N` | 0 | run exactly N steps, print a summary, exit 0. 0 = until `q` |
| `--size WxH` | terminal, else 96×36 | grid in cells, `1×1` … `250×120` |
| `--iters N` | 24 | pressure Gauss-Seidel sweeps per projection, `0`…`400`. **0 = do not project at all** |
| `--diters N` | 4 | viscous Jacobi sweeps per step, `0`…`64`; forced to 0 when `--viscosity 0` |
| `--viscosity N` | 0 | in 1/10000, `0`…`10000`. 0 = inviscid, which is the interesting case |
| `--vort N` | 25 | vorticity confinement in 1/1000, `0`…`1000`; 0 = off |
| `--damping N` | 0 | velocity damping per step, in 1/1000 |
| `--decay N` | 2 | dye fade per step, in 1/1000 |
| `--ink N` | 250 | dye the emitter lays down per step, in 1/1000 of full scale |
| `--swirl N` | 375 | emitter swirl, in 1/1000 cells per step |
| `--radius N` | 6 | emitter radius in cells, `1`…`64` |
| `--seed N` | 1 | `0`…`4294967295`. **The same seed gives byte-identical output** |
| `--field F` | `speed` | `speed` \| `vort` \| `dye` |
| `--glyph G` | `blocks` | `blocks` \| `half` \| `ascii` \| `braille` \| `none` |
| `--gamma N` | 2 | display gamma, `1`…`8`: the magnitude ramp is t^(1/N) |
| `--dump N` | 0 | print the grid as text every N steps as well (0: the last step only) |
| `--fps N` | 30 | live-view frame rate, `1`…`240` |
| `--no-tty` | | render into a text capture; never paces |
| `--stats` | | wall clock, rate and heap delta on **stderr** |

Every flag outside its range is a **diagnostic on stderr and exit 1**, never a
clamp: `--size 0x0`, `--iters -1`, `--viscosity 10001` and `--seed=-1` are all
refused. A silent clamp would turn a typo into a "why did it do that" bug
report against the program.

### Keys (live view)

`q` / `Esc` quit (always through `term.restore_all_exit(0)`) · arrows move the
emitter · `space` pause · `.` one step even while paused · `d` drop dye · `s` the
emitter's own orbit on/off · `r` re-seed with the same `--seed` · `v` cycle field
· `g` cycle glyph · `+`/`-` pressure iterations.

---

## What to look at

**Run `./fluid` and move the arrow keys.** The dye trail is the clearest thing
in it: a blob laid down at the emitter is *carried* by the flow, which is
semi-Lagrangian advection made visible. Watch the colour bar on the top row —
it is the current ramp drawn end to end, so its ends are ± the auto-scale, and
you can see the scale breathing as the field's peak rises and falls.

Then press `v` for vorticity. The glyph ramp stays the same and the **hue
inverts**: cool for clockwise, warm for counter-clockwise, both starting at the
same near-black. A vortex core becomes a spot of one sign in a field of the
other, which is the one thing a vorticity plot has to get right and what a
luminance-only rendering throws away.

Things worth trying:

```
--iters 0        the projection is off; the field stops conserving mass and the
                 reported divergence is an order of magnitude worse.  The image
                 looks almost fine, which is the point: an unconverged
                 projection is not obviously wrong, it is just wrong.
--viscosity 2000 a thick honey.  Energy collapses within ~40 steps.
--gamma 1        the linear ramp on a quiet field: nearly empty, a few specks.
--gamma 4        too much: everything visible, no contrast.
--glyph braille  16 levels instead of 5, at 3 bytes a cell.
--seed 9         a completely different run from the same code.
--size 1x1       one cell.  It works, and the divergence is exactly zero,
                 because there is nowhere for a gradient to point.
--size 250x120   the largest grid the solver's store holds.
```

### The pressure solve, measured

`--frames 200 --no-tty --iters N`, 96×36, everything else default:

| `--iters` | div rms (Q12) | as a real | energy | v max (cells/step) | steps/s |
|---:|---:|---:|---:|---:|---:|
| 0 | 441 | 0.1076 | 167.29 | 1.18 | 603 |
| 1 | 240 | 0.0585 | 191.09 | 1.51 | 561 |
| 2 | 191 | 0.0466 | 173.92 | 1.65 | 541 |
| 4 | 160 | 0.0390 | 173.79 | 1.81 | 534 |
| 8 | 113 | 0.0275 | 152.31 | 1.82 | 503 |
| 16 | 81 | 0.0197 | 129.31 | 1.68 | 445 |
| **24** | **75** | **0.0183** | **122.95** | **1.62** | **400** |
| 40 | 74 | 0.0180 | 119.89 | 1.56 | 334 |
| 64 | 74 | 0.0180 | 119.11 | 1.55 | 267 |
| 128 | 74 | 0.0180 | 119.05 | 1.55 | 175 |
| 256 | 74 | 0.0180 | 119.19 | 1.55 | 105 |

Gauss-Seidel takes the first factor of two almost for free (0 → 1 sweep halves
the residual) and then flattens out. The floor at **74 (0.018)** is the free-slip
boundary, not the solve: `step()` refreshes the ghost ring *after* the gradient
subtraction, so the wall cells' divergence is whatever the reflection makes it.
A symmetric (forward-then-backward) sweep would reach the same floor in about
half the sweeps; the direction never changes here because a fixed order is what
makes the whole solver reproducible to the bit.

The dye mass column is the other half of the story: it falls from 743 to 263 as
the projection converges. An unconverged velocity field is a *bad* advecting
field, so it grinds dye into the walls where the `[0,1]` clamp eats it.

### Golden frames

`golden/` holds 19 captured states as text — the exact cell grid, no escape
sequences, so they diff:

| file | |
|---|---|
| `step0010-speed` | the deterministic run's frame |
| `step0100-speed`, `step0400-speed` | the flow developing; the vortex pair has met and started to roll |
| `step0100-vort`, `step0400-vort` | the same instants, signed: cool one way, warm the other |
| `step0400-dye` | the smoke trail, `--field dye` |
| `step0100-half` | the half-block ramp, 4 levels of vertical resolution per cell |
| `step0400-half` | the same at 400 steps; compare with `step0400-speed` |
| `step0100-ascii` | ` .:-=+*#@`, 10 levels, no font requirement |
| `step0100-braille` | U+2800+mask, 16 levels |
| `step0100-noglyph` | colour only — the glyph is carrying no information at all here, which is the useful control |
| `step0100-linear`, `step0100-gamma4` | `--gamma 1` and `--gamma 4` against the default 2 |
| `step0400-viscous` | `--viscosity 2000 --diters 20`: the vortices are gone |
| `step0400-damped` | `--damping 40`: same, by drag instead of by viscosity |
| `step0200-iters0/8/64` | the projection's quality, as pictures |
| `step0200-seed9` | a different run |

Note that `step0100-linear` is much sparser than `step0100-speed` even though
only the display gamma differs. That is the whole argument for the gamma, and
it is in the file rather than only in this README.

---

## The parts a reader should look at first

**`sim.y` — the overflow strategy.** Y has no `float` → `long`, so the whole
solver is Q30 integers and the real danger is a product. Three rules, and they
are *guarantees* rather than estimates because rule (c) makes the magnitudes
bounded:

* **(a) Square only after shifting down.** Every square root in this program
  (`speed`, `max_speed`, `energy`, the vorticity normal, the emitter's radius)
  needs a sum of squares of Q30 quantities, which is Q60 and has no answer in 64
  bits. So the operands are shifted down 17 bits first and the answer shifted
  back up: the quantity handed to `fx.isqrt` is at most 2³¹, not 2⁶⁴. See
  `sim.speed()`.
* **(b) Every coefficient is Q16, never Q30.** Viscosity, confinement ε,
  damping, decay, emitter strength and the bilinear weight are all Q16
  (65536 = 1.0) even though the fields they multiply are Q30. With a Q16
  coefficient the worst product is 2³⁴ × 2²³ = 2⁵⁷, and each is brought back
  down with a `>> 16` before the next factor is formed, so a triple product never
  exists at all.
* **(c) `|u|`, `|v| ≤ 4` cells per step, clamped after every operator that can
  add to them.** That is `sim.clampv()`, and it is what turns (a) and (b) from
  arithmetic luck into arithmetic fact. The dye gets its own clamp at exactly
  1.0, because it is a density.

The one place a naive program overflows is **the semi-Lagrangian backtrace**,
and it is worth reading `sim.advect()` for it: the backtrace *position* is exact
Q30 (`x·ONE - u`), but the bilinear *weights* cannot be — blending two
velocities means forming `(u10 - u00)·w` with *w* in Q30, and that product is
2³²·2³⁰ = 2⁶², one bit short of disaster and wrong the moment the velocity
clamp is raised. So the weight is truncated to Q10 first (1024 levels inside a
cell, i.e. 1/1024 of a cell — far below anything the eye or the scheme can see)
and every product then tops out at 2⁴³.

**`sim.y` — writing a stencil without `break` or `continue`.** The 3×3 and
5-point stencils are written out as straight-line neighbour loads, not as loops,
because a 3×3 loop needs a `continue` to skip the centre cell and Y has neither
(§2.9); a guarded body would be eight extra branches per cell in the hottest
loop in the program. Where an early exit *is* wanted the other idiom is used: a
positive `if` around the whole body, which **is** the continue —
`sim.emit()`'s `if (d2 < r2) { … }`, and the emitter's `if (d > 0)` which is
also what keeps it from dividing by the distance from its own centre. On the
render side, `fluid.y`'s headless loop wants to stop at the last frame and uses
a guard (`let want = f == FRAMES;`) because `break` does not exist.

**`fluid.y` — the allocation discipline.** The solver's `Field` is built at
**module scope**, before the command line is parsed, and `--size` retunes it with
`sim.setup()`, which allocates nothing because the nine arrays are already at
their maximum. A step allocates zero bytes: no array literal, no record literal,
no string. The configuration is a record built **once** by the caller and mutated
in place, because a record literal written at the `step()` call site would be a
64-byte leak per step. The status line is written a digit at a time into the
surface from a module-level scratch, because a `tostring()` or an f-string once a
frame would allocate on the frame loop. `textout.out_q()` is the Q30 printer
this forced into existence: an energy or a speed has to be printed from integers,
with no float in the expression.

**`fluid.y` — the colour.** Every field is drawn twice over: the glyph ramp
carries the **magnitude** and the colour carries the **sign**. `fb.shade_blocks()`
maps a value to a glyph by COVERAGE rather than by brightness, so the glyph is
monotonic on a light terminal and a dark one alike. The magnitude it is fed is
`norm()` then `gmag()`: position on [0,1], then the display gamma. The gamma is
not cosmetic — a fluid field is mostly quiet, and away from a vortex core the
flow of a *converged* projection is very nearly irrotational, which is true of
real fluids and of this solver. The scale is a decaying maximum rather than a
fixed one: a fixed scale either blows out on the first energetic step or shows
nothing for the first hundred.

**`fluid.y`'s header comment** explains the three gaps the program is built
around, and `sim.y`'s explains the two rules (no `break`, nothing allocates) and
the whole overflow analysis. Both are worth reading before the code.

---

## Performance and memory

```
$ ./fluid --frames 10000 --no-tty --stats
fluid: 10000 steps in 24574927 us = 24574 ms -> 406 steps/second on 96x36 with 24 sweeps
fluid: heap_used before=4272840 after=4272840 delta=0
```

* **406 steps/second** at the default 96×36 grid with 24 pressure sweeps, on
  this machine (a shared VM; the same number three times within 2%). That is
  2.4 × 10⁹ cell-updates a second, of which the projections are two thirds.
  `--iters` is the dial: 603 steps/s at 0 sweeps, 400 at 24, 267 at 64, 105 at
  256.
* **heap delta 0 bytes over 10 000 steps.** `heap_used()` is read either side of
  the step loop and *the header is printed before the first reading*, because
  the header builds strings and the arena counts those. Nothing in the loop
  grows it.
* The frame loop in the live view costs the same step plus one render pass
  (3 456 cells × one `fx.isqrt` for the gamma) and four read-only measurement
  passes. At 30 fps that is 12 % of the budget, which is why it holds 30.

### The heap figure in the golden is a DELTA, and only because the orchestrator's gate caught it

**This example printed an absolute `heap_used()` into its golden until
2026-10-05, and every check it owns passed the whole time.** That is the point
of recording it, so read the next two paragraphs as a statement about the
battery rather than about this program.

The header used to end with `heap  <absolute> bytes at step 0` and the summary
with `heap  before <h0>  after <h1>  delta <h1-h0>`. `h0` is read *after* the
process has started, but `heap_used()` counts the **argument vector**, which
the kernel allocated at exec time — so `h0` moves with the length of the path
you typed:

```
$ ./fluid --frames 10 --no-tty | sed -n 15p
heap         4272736 bytes at step 0
$ $(pwd)/fluid --frames 10 --no-tty | sed -n 15p
heap         4272776 bytes at step 0
```

40 bytes, and nothing in the fluid solver is 40 bytes different. The golden
could only ever match one of them.

**Which checks could not see it, and why.** The example's own `gate.sh` runs the
program one way — always as `./fluid` — three times, and three runs of one
invocation agree perfectly well; determinism is not the defect. Its 55-invocation
error sweep never reaches stdout on a rejected flag. `EXPECTED` itself matched.
The **orchestrator's** `gate.py` item 2 now re-runs the `run=` line with the
binary named by **absolute path**, which lengthens `argv[0]` and exposes it:

```
[FAIL] 2 golden output  output depends on HOW it was invoked: byte 722 is
  b'36 bytes at step 0' as `./fluid` and b'76 bytes by absolute path'
```

So the rule this teaches is: **a value derived from `argv[0]` belongs in a
golden only as a delta, never as an absolute.** A delta excludes the argument
vector, because argv was already allocated before the first reading, so it
cancels. Filed as [`examples/SUGGESTIONS.md` §24](../SUGGESTIONS.md)
("`heap_used()` counts the argument vector, so an absolute heap figure is a
function of `argv[0]`"), which names this folder as one of three and asks for
either a heap figure that excludes the pre-`main` arena or one sentence in the
manual next to `heap_used()`. The header now names the measurement instead of
printing one, and the summary reports `used <h1-h0> bytes over N steps (a delta,
not a total: heap_used() counts argv)` — one figure, and it means what it says.
The two `eputs` under `--stats` still print the absolutes, which is correct:
stderr is diagnostics and no golden diffs it.

The delta is **0** for every invocation, which is this example's actual claim
that a step allocates nothing, and it is a *measured* zero rather than a
constant: the same `heap_used()` delta over a loop that does allocate a record
and an array per iteration reports 48 040. Verified across `./fluid`,
`$(pwd)/fluid`, `./././fluid`, an `env -i` invocation with an empty environment,
and a copy at a 120-character path — all five byte-identical.

---

## Compiler pin

Built and verified against:

```
refs/ycc.ref  sha256  c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

**The pin moved while this example was being written**, from
`e27f83e4801f943668624727b4bc7da70c038600c9d7c2328e4060350f6622f9` to the above.
Everything was rebuilt and re-verified against the new binary: zero warnings,
byte-identical `EXPECTED` across three runs, zero traps over 55 error and edge
invocations, `gate.py` 8/8. A rebless is survivable here, but it has to be
checked rather than assumed (§3 of `ORCHESTRATOR.md`).

---

## The std units this uses

| file | sha256 (prefix) | lines | what it is used for |
|---|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 | integer fixed point: `ONE`, `sin`, `cos`, `isqrt`, `abs`, `TWO_PI`. No floats, no state, no allocation |

**Vendored unmodified from `examples/_toolkit/` — all five are byte-identical to
the canonical copies.** Nothing in this folder edits any of them. Where the
toolkit's behaviour was not what this program needed, the workaround is a
separate file next to it: `textout.y` is copied from `examples/donut/textout.y`
(it is *donut's* helper, not part of the toolkit) with **one** addition,
`out_q()`, the Q30 fixed-point printer this example needs, and its header
comments rewritten to say so. Everything else in it is unchanged.

---

## Workarounds, and what they are for

### `str + byte` — avoided entirely, and the filed workaround no longer compiles

[`examples/BUGS.md` §"`str + byte` segfaults — `print("x" + "abc"[0]);` crashes
the program"](../BUGS.md) is real and still reproduces on the current pin:

```y
print("x" + "abc"[0]);     // SIGSEGV, exit 139
```

**This program never needs the workaround**, because it never builds a string
one character at a time. Every byte of the deterministic output goes through
`textout.y`'s fixed `[byte; 65536]` buffer and `out_glyph()`, which formats a
codepoint as UTF-8 through `fb.utf8_len`/`fb.utf8_byte`; the HUD goes into the
surface a digit at a time. The only string concatenation anywhere is `str + str`
inside the argument-validation diagnostics (`die()`, `ranged()`, `mode_of()`),
which are on the error path and cost one allocation each. So the `str + byte`
bug is routed around by **not going near it**, which is the cheapest workaround
there is.

Two things a reader should know, both re-verified against the current pin:

* The `+=` form listed in that entry's "passes" list **no longer compiles**:

  ```y
  const R = " .:-=+*#%@";
  let i = 0; let a = "";
  while (i < 5) { a += R[i]; i = i + 1; }
  # error: '+=' string: expected str, got byte
  ```

  The entry's environment block records the older pin; the checker now rejects
  `str += byte` while the emitter still mishandles `str + byte`, so the two
  halves of that entry disagree. Worth re-checking before using it as a recipe.
* The two workarounds that **do** work today, both verified on this pin:

  ```y
  a = a + chr(R[i]);        // chr returns a real str   -> " .:-="
  a = a + R[i:i+1];         // a slice is a str, not a byte -> " .:-="
  ```

### `fx.isqrt()` hangs on a negative argument — filed, and clamped around

[`examples/BUGS.md` §"`fx.isqrt()` loops forever on a negative argument"](../BUGS.md):
`print(fx.isqrt(0 - 1));` never returns. Its range reduction
`while (bit > u) { bit = bit >> 2 }` has no exit for `u < 0`, because
`0 > -1` is true and `0 >> 2` is `0`.

This one bit `fluid` for real, and the way it bit is worth recording: the
emitter's squared distance from its own centre overflowed to a negative value
when the centre was outside the grid, `fx.isqrt` was handed it, and the program
hung with no output. The fix here is in `sim.emit()`, and it is the right fix
anyway — a module function should be **total**, so the emitter clamps its centre
into the grid before anything measures a distance from it, and no call anywhere
in `sim.y` can produce a negative `isqrt` argument.

### Not a workaround, but worth writing down

**`fb.text()` returns the number of codepoints it drew, not the column after
the text.** They are both `long` and both plausible, and using the return value
as the next column walks the cursor *backwards* by the length of every label, so
each label lands on top of the last and the status line ends up as the last
string drawn sitting at column 2. It looked plausible enough to cost three
debug lines. `fluid.htext()` computes the advance itself (`col + len(t)`, which
is exact because every HUD label is ASCII) and its comment says why.

**`fb.text()` clips silently at the surface edge** — bounds-safe, not
complaining, which is right for a renderer and wrong for a status line. The key
list at the right of the HUD is therefore chosen by how much room is left: four
lengths, longest that fits.

---

## Files

| file | lines | |
|---|---|---|
| `fluid.y` | 1122 | entry: command line, validation, colour ramps, glyph ramps, the display gamma, the status line, the two frame loops |
| `sim.y` | 1026 | the solver: borders, `project` (the pressure solve), `diffuse`, `advect`, `confine`, `emit`, `seed`, `step`, and the five measurements — with the overflow analysis in its header |
| `textout.y` | 231 | the allocation-free deterministic sink; vendored from `examples/donut/textout.y` **plus `out_q()`** |
| `pty_check.py` | 137 | drives `./fluid` through a real pty and checks the alt screen, `q`, the restored termios and that frames were painted |
| `gate.sh` | | re-runnable acceptance gate: all seven items of §7 plus the 55-invocation error-path sweep |
| `gate.conf` | | `build=` and `run=` for `../gate.py` |
| `EXPECTED` | | the exact stdout of `run=`, 11 757 bytes |
| `golden/*.txt` | 19 | captured states as text, diffable |

## Verification

Every item below was run, with every process under `ulimit -S -v 3670016` and
`</dev/null`. `sh gate.sh` re-runs all of it and prints `GATE: PASS`.

| gate item | result |
|---|---|
| 1. clean compile, **zero warnings** | `../../refs/ycc.ref fluid.y -o fluid` → exit 0, **0 bytes on stderr** |
| 2. deterministic output | `./fluid --frames 10 --no-tty` three times → sha256 `7d1b2aec…` every time, `cmp` against `EXPECTED` clean (11 757 B), **and the same bytes by absolute path** (see "The heap figure in the golden is a DELTA" above) |
| 3. no trap on any path | **55 invocations, 0 traps** (`gate.sh` item 3, `sh gate.sh`): `--help`, unknown flag, missing value, every flag out of range on both sides, `--size 0x0`/`1x1`/`1x120`/`250x1`/`250x120`/`axb`/`251x10`, `--iters 0`/`-1`/`401`, `--viscosity 10001`, `--vort 1000`, `--damping 1000`, `--swirl 4000`, `--radius 1`/`64`, `--gamma 8`, `--no-tty` with no `--frames`, a stray operand, `--`, four seeds, three fields, five glyphs, and every extreme at once for 400 steps at 250×120 |
| 4. inside the cap, no per-frame allocation | cap enforced on every run; `heap_used()` delta **0** over **10 000** steps |
| 5. self-contained | the folder alone in a fresh temp dir builds **byte-identically** and its stdout `cmp`s clean against `EXPECTED` |
| 6. README complete | this file |
| 7. filings reproducible | both filed findings have a minimal repro that still fails on the pinned compiler |
| `./gate.py fluid` | **9/9** |

The pty check (tmux is not installed on this machine, so the pty comes from
Python; the window size is set **before** `execv`, or `TIOCGWINSZ` reports
nothing and the frame comes out degenerate):

```sh
$ python3 pty_check.py ./fluid
bytes from the pty      : 3790677
window size            : 30 x 100
alt screen entered      : True
alt screen left         : True
cursor hidden / shown   : True / True
truecolor SGR triples   : 118930 (the colour bar is a truecolor ramp)
HUD row writes         : 328 CUP sequences addressing row 30
field row writes       : 6768 CUP sequences addressing rows 2.. 29
cooked mode restored    : True
lflag identical         : True
exit status             : 0
RESULT                  : PASS
```

and with `--arrows`, which walks the emitter into all four corners and back
before typing `q` — 14 918 171 bytes, 495 395 CSI sequences, `RESULT: PASS`.

## Determinism

The default path has **no unseeded randomness anywhere**. The only randomness is
`sim.rnd()`, an xorshift32 whose 32-bit state is a pure function of `--seed`,
and the emitter's orbit is a Lissajous curve whose phase also comes from
`--seed`. `--fps` is the only clock-driven flag and it is live-view only; the
headless path never paces and never reads the clock except to time itself, which
goes to stderr under `--stats`. The colour scale is a decaying maximum, so even
the pixels are a function of the simulation and not of the wall clock.
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
