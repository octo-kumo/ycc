# `examples/_toolkit/` — shared modules for the examples campaign

Shared, tested code the examples vendor (§4 of `ORCHESTRATOR.md`). An example
**copies** the file it wants into its own folder; nothing imports across folders
at run time.

> This file is written by the `fx.y` (wave 0a) agent. The other modules in this
> folder landed in parallel — add your section, do not replace the file. The
> authoritative copy of the `fx` documentation is the header comment of `fx.y`
> itself, which is deliberately long enough to stand alone.

| file | what | self-test |
|---|---|---|
| `fx.y` | integer fixed-point maths: no floats, no `sin`, no `sqrt` | `fx_test.y` — 292 checks, exits 0 |
| `term.y` | termios raw mode, window size, key decode, alt screen | `term_test.y`, `term_pty_test.py` |
| `fb.y` | ANSI framebuffer: SGR, truecolor, glyph ramp, row diffing | `fb_test.y` |
| `args.y` | flag parsing, usage text, exit codes | `args_test.y` — 57 checks |
| `time.y` | sub-millisecond pacing, fps meter | `time_test.y` — 47 checks, ~7 s of real pacing |

`time.y` had **no** self-test while wave 0d's gate criterion named it
explicitly ("sustained target fps"), which made it the one wave-0 module
whose criterion was a *number* with nothing checking that number.
`time_test.y` closes that, and it is the only suite here that needs no pty —
but it does need real time, because a sustained *rate* cannot be checked
without pacing frames for seconds:

```
(ulimit -S -v 3670016; \
 ../../refs/ycc.ref time_test.y -o /tmp/tim && /tmp/tim) </dev/null
```

It measures the sustained rate **from outside** `time.y`'s own meter, and
that is deliberate rather than redundant. `fps_new(win_us = 500000)` closes
a half-second window holding ~15 frames at 30 fps, so one frame either way
is ~6.7% and the on-screen number cannot resolve 29 from 30. An earlier
harness in this campaign read that meter, got 29 against a target of 30,
and nearly filed a defect against an example that was holding **29.99**.

Its allocation section carries a deliberate **control**: a `[0; 4]` literal
per iteration, which *must* move `heap_used()`. If that control ever stops
allocating, every "allocates nothing" result in the file has become
vacuous — so the suite checks its own instrument, and prints what the
control measured.

## Pinned compiler

Everything here was built and tested against one binary:

```
refs/ycc.ref   sha256 fcdae3ccbd5877942ca16c3845a59c5ba06afe1a1eb9afb140dbddd581f304c1
```

**The pin moves.** It moved at least three times while wave 0 was being
written — the reference is being reblessed underneath the campaign, and it has
already gone through `d459af4f…`, `6f873c27…`, `63a4c3d0…` and now this one.
`ORCHESTRATOR.md` §3 and §8, and `SUGGESTIONS.md` item 4, all still quote shas
that are long stale. `refs/SHA256SUMS` is authoritative — re-read it rather
than trusting a sha quoted in any document, including this one.

`fx_test.y` passes 292/292 with **zero warnings** against every one of those
pins, so the module is insensitive to the movement; but if your own README
records a different sha than the line above, say so in your report rather than
reconciling it silently.

Build and run under the memory cap, always with `</dev/null`:

```bash
YCC=/home/yun/Projects/compiler/refs/ycc.ref
sha256sum $YCC                                   # record what you actually used
(ulimit -S -v 3670016; $YCC fx_test.y -o /tmp/fx_test && /tmp/fx_test) </dev/null
```

---

# `fx.y` — integer fixed-point maths

## Why it exists

Y has **no `float` → `long` conversion and no cast syntax at all**
(`ORCHESTRATOR.md` §2.4a). A number a program computes can never leave a
float. And Y has **no `sin cos tan asin acos atan atan2 sqrt exp log pow abs
floor ceil round trunc fmod` and no `PI`** (§2.4b) — they exist nowhere in the
tree. Every program with a curve in it has to write them first, in integer
fixed point, and get the range reduction and the quadrants right. That is what
this file is, written once and tested once.

The shipped `examples/badapple` players already carry all their colour fitting
in `long` fixed point for this reason; `fx.y` is the generalised, tested
version of that discipline.

## The format: Q30 (a.k.a. 1.30)

A `long` `v` holds the real number `v / 2^30`.

```
1.0        == 1073741824        fx.ONE
0.5        ==  536870912        fx.HALF
pi         == 3373259426        fx.PI
one step   == 2^-30 = 9.3132e-10
largest    == 2^62-1            fx.MAX   (a real value of 4.29e9)
```

| | Q16.16 | **Q30 (chosen)** |
|---|---|---|
| least bit | 1.5e-5 | 9.3e-10 |
| relative error on `sqrt(1)` | ≤ 7.6e-6 — **fails a 1e-6 requirement** | 9.3e-10 |
| `mul` with a 64-bit product | exact only for `|a·b| < 2^31` | exact for **every** representable pair |
| `fdiv` | exact | exact |

Q30 was chosen because the gate asks for **1e-6 relative** on `sqrt`, and a
Q16.16 value cannot hold it: its least bit is 1.5e-5, so `sqrt(1)` is out by up
to 7.6e-6 *whatever algorithm you use*. Thirty fraction bits cost nothing to
keep honest on a 64-bit machine, because nothing in this file ever forms an
intermediate it cannot hold:

* `mul` falls back to `mul_wide`, which forms the whole 124-bit product in
  16-bit limbs and keeps the bits — so there is **no range cliff at all**.
  `|a| ≤ 2^31` and `|b| ≤ 2^31` is only the *fast* path, not a limit.
* `fdiv` divides bit-serially and never forms `(a << 30)`.
* `isqrt` is the shift-and-subtract digit recurrence, which squares a number
  below 2^31 rather than the dividend.

The accuracy below is therefore **not a function of the operand magnitude**: the
same error holds at 1e-9 and at 1e9.

## Measured accuracy

Measured against IEEE-754 binary64 on this tree over **3.8 million points**:
`sin`/`cos` at 14400 evenly spaced angles round the circle and over ±500 rad at
a step of 0.001; the inverse functions over their whole domains; `sqrt` over
four ranges; `mul` and `fdiv` over 40000 deterministic pseudo-random pairs
chosen so the product is representable but the *raw* product needs 80 bits (so
the wide path is what is being measured). The argument reduction was checked
**exactly**, as integers, against an 80-digit reference.

| function | worst measured | requirement |
|---|---|---|
| `sin` | 1.5e-9 abs (whole circle), 2.4e-9 abs (±500 rad) | 1e-4 abs |
| `cos` | 1.6e-9 abs (whole circle), 2.4e-9 abs (±500 rad) | 1e-4 abs |
| `tan` | 7.5e-6 **relative** — that is one step | — |
| `atan` | 1.1e-8 abs | — |
| `atan2` | 1.1e-8 abs, every quadrant and every axis; `\|atan2(sin t, cos t) − t\| ≤ 1.1e-8` over `[−π, π]` | — |
| `asin`, `acos` | 1.1e-8 abs over the well-conditioned domain, 5.5e-8 at `\|x\| = 0.99997` where the derivative is 71 | — |
| `sqrt` | **9.3e-10 abs = one step, at every scale** from 2⁻³¹ to 2³²; 1.2e-9 *relative* for `x ≥ 0.1`; exact on every perfect square | 1e-6 rel |
| `isqrt` | exact | — |
| `mul`, `fdiv` | 9.3e-10 abs = one step; 6.9e-12 relative when the result is of order one | — |
| `hypot` | 2e-8 relative | — |

Two of those deserve their reasoning spelled out, because they are *not* bugs
and a caller will otherwise think they are:

* **`sqrt`'s relative error rises for tiny arguments.** The absolute error is
  one step everywhere. At `x = 4.7e-9` the answer is `6.8e-5`, and half a step
  is already `4.7e-10`, so the *relative* figure there is 6.5e-6. A relative
  bound below `x ≈ 1e-6` is not achievable in this format by any algorithm.
* **`tan` cannot exceed `fx.ONE` on this grid.** The `cos` of a Q30 angle is
  either exactly 0 or at least one step, so `|tan| ≤ 2^30` always. At exactly
  `±π/2` the `cos` is 0 and `fdiv(x, 0)` is 0 by the zero-divisor rule, so
  `tan(π/2)` is **0**, not infinity and not a trap. 16 steps away the tangent
  is exactly 2²⁶, 64 steps away exactly 2²⁴.

## Domains and edge behaviour

| call | behaviour outside the obvious domain |
|---|---|
| `sin`, `cos`, `tan` | any `long`. The argument is a Q30 value, so the largest angle is 2⁶³/2³⁰ = **8.59e9 rad = 1.37e9 turns**, accurate throughout. |
| `sqrt` | `x ≤ 0` → 0. Domain `0 ≤ x < 2^33`, i.e. every non-negative `long`; the answer is at most 92682. |
| `isqrt` | whole `long`, `0 ≤ u < 2^62` (the limit of the digit recurrence). Exact. |
| `asin`, `acos` | `\|x\| ≥ 1` → `±fx.HALF_PI` / `0` / `π`. Never divides by a zero root. |
| `atan2` | `(0, 0)` → **0** by convention. `x < 0, y = 0` → `+π`; `y < 0` → `−π`, so the range is the closed interval `(−π, π]`. |
| `fdiv` | `b = 0` → **0**. Saturates at `±fx.MAX` rather than wrapping. |
| `mul` | saturates at `±fx.MAX` rather than wrapping. |
| `hypot` | scales down by an even number of bits; saturates rather than wrapping on the shift back. |
| `fmod` | `b = 0` → 0. |
| `abs` | `abs(-2^63)` overflows to itself; every real argument is far inside. |

Nothing in this file traps. A degenerate argument returns a value, because
traps land on **stdout** (`ORCHESTRATOR.md` §2.6) and corrupt a frame's diff
rather than announcing themselves.

## Guarantees

* **No state.** Every function is a pure function of its arguments. No module-
  level mutable binding, no cached table, no accumulator, no memo. Call `sin`
  ten million times and the ten-millionth answer is bit-identical to the first
  — safe in a render loop, across a `fork`, and from two threads at once.
* **No allocation.** No array, record, string or closure is built on any path
  through the file. `sin` allocates nothing at all. (Y's heap is an arena and
  is never freed, so a per-frame allocation is a leak — §2.7.)
* **Truncation, always toward zero.** Never round-half-even, never round-half-
  up. That is what makes `mul(-a, b) == -mul(a, b)` *exactly*, and therefore
  `atan` and `asin` exactly odd. `sin(-x) == -sin(x)` holds only to a few
  steps — the reduction mirrors the angle onto a different branch of the
  polynomial — and `fx_test.y` asserts 8 steps rather than bit-equality.
* **Odd symmetry where it is cheap**: `mul`, `fdiv`, `abs`, `atan`, `asin` are
  odd step for step. `fmod` is C's `fmod` (the sign follows the dividend).

## Cost

Measured on this machine (shared, so ratios are the useful part):

```
sin      63 ns     atan2   215 ns
mul      33 ns     sqrt    290 ns
```

A whole 80×30 frame of `sin`+`cos` — 4800 calls — costs about **0.3 ms**, so
this is not the bottleneck in any of the visual examples. `mul`'s 33 ns is
mostly loop and call overhead; the wide path is only reached when a product
needs more than 63 bits. A program that imports `fx` and uses one function
links about 10 KB (the linker tree-shakes the rest).

## API

```
CONSTANTS   ONE HALF TWO MAX FRAC_MASK ROUND
            PI TWO_PI HALF_PI QUARTER_PI THREE_QUARTER_PI FIVE_QUARTER_PI
            SEVEN_QUARTER_PI THREE_HALF_PI DEG RAD INV_PI TWO_PI_RESID
            (DEG = radians per degree = pi/180;  RAD = degrees per radian)

CONVERSIONS from_int(n)  to_int(x)  to_float(x)  to_str(x)
            trunc(x) floor(x) ceil(x) round(x)          -- see the convention

ARITHMETIC mul(a,b)  fdiv(a,b)  fmod(a,b)
            isqrt(n)  -- whole long in, exact root out
            sqrt(x)   -- fixed point in and out
            hypot(y,x)

TRIG       sin(x) cos(x) tan(x)
            atan(x) atan2(y,x) asin(x) acos(x)

ANGLES     wrap_pi(x)   -- into (-pi, pi]
            wrap_2pi(x)  -- into [0, 2pi)
            to_deg(rad) to_rad(deg)

UTILITIES  abs imin imax clamp lerp
```

### The conversion convention — the one thing callers must get right

There is no `float` → `long` in the language, so these four had to choose, and
the choice is deliberate:

```
from_int(n)   n   ->  n * 2^30                  into the format
to_int(x)     x   ->  a whole `long`, TRUNCATED TOWARD ZERO  (-1.9 -> -1)
trunc(x)      x   ->  the whole-number Q30 value, toward zero
floor(x)      x   ->  the whole-number Q30 value, <= x
ceil(x)       x   ->  the whole-number Q30 value, >= x
round(x)      x   ->  the whole-number Q30 value, nearest, halves AWAY FROM zero
```

`floor`, `ceil`, `round` and `trunc` answer **in the units they were asked in**,
as a multiple of `fx.ONE`; `to_int` is the one that hands back a plain integer.
So:

```
fx.floor(x)              a whole number you keep doing arithmetic with
fx.to_int(fx.floor(x))   the same number as an integer, to print or compare
```

`round` is half-**away from zero** (`round(2.5) = 3`, `round(-2.5) = -3`), not
banker's rounding, because half-to-even is not odd-symmetric and `sin(-x) ==
-sin(x)` is worth more than the statistical nicety.

`to_str(x)` prints six decimals with a round-half-up carry, matching what
`tostring` does with a float, so the two read alike: `"3.141593"`,
`"1.414214"`, `"-0.750000"`. `to_float` exists only so a value can be handed
to code that is already float; the fixed-point path never uses it.

### Worked examples

```y
import fx;

// a spinning point: 80 columns, 30 rows
let cx = fx.from_int(40);
let cy = fx.from_int(15);
let r  = fx.from_int(10);
let sx = fx.mul(r, fx.cos(a));
let sy = fx.mul(r, fx.sin(a));
let col = fx.to_int(fx.add(cx, sx));
let row = fx.to_int(fx.sub(cy, sy));

// perspective divide, without ever leaving integers
let d  = fx.sub(z, fx.mul(fx.from_int(30), fx.ONE));   // 30 units of depth
let sx = fx.fdiv(fx.mul(x, fx.from_int(60)), d);

// a length
let len = fx.hypot(dx, dy);

// colour coverage 0..64 as a fraction
let t = fx.fdiv(coverage, fx.from_int(64));

// folding an angle that has run for a while
let heading = fx.wrap_pi(fx.add(heading, delta));

// a smooth 0..1 oscillator
let k = fx.mul(fx.HALF, fx.add(fx.ONE, fx.sin(phase)));
```

## Running the self-test

```
$YCC = /home/yun/Projects/compiler/refs/ycc.ref      # the sha at the top
(ulimit -S -v 3670016; $YCC fx_test.y -o /tmp/fx_test && /tmp/fx_test) </dev/null
```

Output is one labelled line per check, then a summary; the exit code is 0 only
if every check passed.

```
-- 5. sin, cos, tan ---------------------------------------------
PASS  sin(0)  (0 steps)
PASS  sin(pi/2)  (0 steps)
...
PASS  the 33-entry float64 table of sin, cos, tan
...
=================================================================
292 checks, 0 failed
largest |error| any near() check saw: 912313 steps = 0.000850   at  hypot(1e6, 1e6) is 1414213.5623730
one step is 2^-30 = 9.313225746154785e-10, so that is 912313.0 steps of the fixed-point grid
RESULT: PASS
```

The `near` helper prints the error **to six decimals with an f-string** (there
is no `printf`) *and* in steps, because at this accuracy `0.000000` is the
normal reading and the step count is the interesting part. A failing check
prints got, want, error and tolerance.

What it covers, in nine sections:

1. **constants** — every one is what the header says it is, and `4·π/4 = π`
2. **scalars** — `floor`/`ceil`/`round`/`trunc`/`to_int` on both signs, the
   `to_str` carry out of six nines
3. **`mul`, `fdiv`, `fmod`** — exactness on closed-form cases that *must* take
   the 80-bit path, oddness step for step, saturation, zero divisor,
   `quotient × divisor == dividend`
4. **`isqrt`, `sqrt`, `hypot`** — exact on `n²`, `n²−1`, `n²+2n` for
   `n < 200000`; `sqrt(x²) == |x|`; monotonicity; perfect squares to `4000²`
5. **`sin`, `cos`, `tan`** — known values, a 33-entry float64 reference table,
   `sin²+cos² = 1` over 4000 angles, symmetry, periodicity, monotone on
   `[0, π/2]`, exact at every multiple of `π/2` for four turns, and
   `1e6 / 1e9 / 8e9` rad
6. **`atan`, `atan2`, `asin`, `acos`** — every quadrant and every axis, the
   `atan2(sin t, cos t) = t` round trip over 20000 angles, monotonicity,
   `asin(x)+acos(x) = π/2`, and the domain guards
7. **`wrap_pi`, `wrap_2pi`** — folding, and that `sin`/`cos` come back
   *bit-identical* through it
8. **no drift** — 20000 repeats of the same call compared bit for bit, then
   20000 calls with *different* arguments, then the same values re-checked
   against the reference table
9. **no trap** — every degenerate argument returns

Determinism: the test is byte-identical across repeated runs (verified three
times, `cmp`-clean). It runs in about a second and stays far inside the 3.5 GiB
cap.

## Compiler workarounds in this file

Nothing here is a bug in Y, and nothing here is patched in the compiler. See
`examples/BUGS.md` (empty) and `examples/SUGGESTIONS.md` for the ledgers.

* **No `float` → `long` and no cast syntax** (§2.4a) — the reason this file
  exists. Already filed as `SUGGESTIONS.md` §2. Worked around by making the
  whole library integer, and by giving callers `to_int`/`from_int`.
* **No maths builtins and no `PI`** (§2.4b) — the other reason. Already filed
  as `SUGGESTIONS.md` §1.
* **No `break`, no `continue`** — `TODO.md` §5. Routed around with guard flags
  and explicit terminal assignments, and by wrapping loop bodies in positive
  conditions. `fx.y` has one `while` with a `go` flag (`sqrt`'s Newton loop)
  and one nested `if/else if` chain (`sin`'s quadrant fold).
* **`print(a, b)` concatenates with no separator** — documented in
  `docs/src/09-builtins.tex:261`, so not filed; the test builds its labels with
  `+` and `tostring`.
* **The Q30 constants are hand-computed decimals.** Each is
  `round(exact × 2^30)`; recompute them with an arbitrary-precision tool if you
  change one, and keep `TWO_PI` and `TWO_PI_RESID` consistent — the argument
  reduction's accuracy depends on the pair (see the comment on
  `TWO_PI_RESID`).

## Vendoring

Copy `fx.y` into your example's folder and import it there. Do not import
`../_toolkit/fx.y`, and do not edit the copy: if you need different behaviour,
add your own file beside it. Record which revision you froze in your README.

`fx.y` has no dependencies beyond itself — no other toolkit module, no std
module, no asset file — so a vendored copy is exactly this one file.

## Errata in the frozen sources

The frozen files are **byte-identical copies** vendored into every gated
example, so a fix here would invalidate their recorded shas and force a
re-gate of examples that already passed. Where a frozen file is wrong, the
correction is recorded here instead of edited in.

**`term.y` §`read_key_timeout` — the header comment is wrong by 10×.** It
says the deadline is "rounded UP to the next 10 ms and a request below 10 ms
becomes 10 ms". The code is `let ds = (ms + 99) / 100;` — **100 ms**, because
`VTIME` counts *deciseconds*. The comment should read "the next 100 ms".

The code is right; only the comment is wrong. Measured on the pinned compiler
`c53cc41524a7baa2`: **five `read_key_timeout(1)` calls took 518 ms** (~104 ms
each), which is the 100 ms figure, not the 10 ms the comment claims.

This matters more than a stale comment usually does, because the failure is
silent and misattributes itself. A renderer with a 33 ms frame period that
polls for a key with `read_key_timeout(1)` spends ~100 ms per frame, so every
frame lands a full period late, the pacer drops every frame, and the program
reports **~0.6 fps with its frame counter stuck on 1**. It presents as "the
animation is slow", so it survives review.

**Rule for any live view: poll with `read_key_timeout(0)`** — non-blocking,
returns `KEY_NONE` immediately — and let `time.y`'s pacer own the frame
deadline. This is what `life.y` does, and it is why `life` holds 30.00 fps
where a 1 ms poll would not.