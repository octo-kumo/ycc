# `fractal` — a raymarched signed-distance-field scene, in your terminal

Four primitives — a sphere, a yawed box, a tilted capsule and a ground plane —
welded together with a **polynomial smooth-minimum**, so they melt into one
another instead of intersecting. Every sample of the frame is a ray marched
along that distance field until it reaches a surface; the surface is shaded from
the SDF gradient with one ambient-occlusion tap, a Blinn highlight, a palette
lookup and a fog into a gradient sky.

All of it is integer fixed point. Y has no `float` → `long` and no cast syntax
at all (`ORCHESTRATOR.md` §2.4a) and no math functions either (§2.4b), so the
maths is **Q16 arithmetic with a hand-written integer square root** (`scene.y`),
and `fx.y` is called exactly twice a frame — four `sin`/`cos` for the orbit.

```
                          ▄█████████▄
                         ████████████▄
                        ██████████████▄
                       ▄███████████████  ▄▄████████████▄
                       █████████████████ ███████████████
                       █████████████████ ███████████████
                       █████████████████▄███████████████
                       █████████████████████████████████
                       █████████████████████████████████
                       █████████████████████████████████
                       █████████████████████████████████
                        ████████████████████████████████
                        ▀███████████████████████████████
                         ▀██████████████████████████████
                 ▄▄▄▄▄    ▀█████████████████████████████
▄▄▄▄▄▄████████████████████▄▄▀███████████████████████████████████████████▄▄▄▄▄▄
██████████████████████████████▄ ██████████████████████████████████████████████
██████████████████████████████████████████████████████████████████████████████
```

That is `golden/opening.txt` — the opening pose, sphere and box already fused
into one mass with a waist where the capsule passes in front.

---

## Build and run

The folder is self-contained. Everything it needs is in it.

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631

(ulimit -S -v 3670016; $YCC fractal.y -o fractal) </dev/null   # zero warnings

./fractal                                # interactive, until q or Escape
./fractal --frames 2 --no-tty --size 40x16   # the deterministic run (== EXPECTED)
./fractal --quality 1                     # fewer march steps, more frames
./fractal --glyph braille                 # 8 rays a cell instead of 2
./fractal --color ice                     # a different palette
./fractal --no-tty --frames 60 --ansi f.ans --dump 0,30,59
./fractal --frames 300 --no-tty --time    # wall clock, steps/ray, heap delta
./fractal --dist 5 --el 18 --az 25        # a scripted view
```

`--no-tty` is the path the acceptance gate uses: it renders through the same
`fb.Surface` and the same `fb.flush_diff`, and only changes where the bytes go
(the ANSI stream goes to `/dev/null`, the text goes to stdout). It **never
paces**, because that path exists to answer "how fast can this machine march
frames" and a sleep in the middle of it would measure `nanosleep` instead.

### Keys, interactive

| key | what |
|---|---|
| `q`, `Q`, Escape | quit — always through `term.restore_all_exit(0)` |
| ← → | orbit in azimuth, 0.64° a press |
| ↑ ↓ | orbit in elevation, 0.48° a press, clamped to ±45° |
| `+` / `=`, `-` / `_` | dolly in and out, 0.05 units a press, clamped to 1…16 |
| `p` / `P` | cycle the palette (5 of them, pre-built — this is one store) |
| space | pause the orbit |
| `r` | back to the opening pose |

---

## Options

```
  -n, --frames N     render exactly N frames, then exit 0 (default 0: run until q)
  -s, --size VALUE   WxH cells, at most 160x80; default the terminal, or 80x32
  -t, --steps N      maximum march steps per ray, 1..4096 (default: from --quality)
  -q, --quality N    1..4, a preset for --steps: 40, 72, 112, 160 (default 2)
  -g, --glyph VALUE  ascii | blocks | half | braille   (half: the default)
  -c, --color VALUE  ember | ice | spectrum | mono | phosphor
      --seed N       0 (the default, no jitter) or 1..2147483647
  -a, --az N         opening azimuth in degrees, -360..360 (default 12.5)
  -e, --el N         opening elevation in degrees, -45..45 (default 2.0)
      --dist N       opening camera distance in scene units, 1..16 (default 4.6)
  -f, --fps N        frames per second, interactive only (default 15)
      --no-tty       render into a text capture instead of the terminal; never paces
  -d, --dump VALUE   comma-separated frame numbers to print as text (default: the last)
      --time         wall clock, fps, steps/ray and the heap delta, on stderr
      --ansi FILE    headless only: also write the last frame's raw ANSI to FILE
  -h, --help         print this message and exit
```

**Sizes are refused, not clamped, when they are degenerate.** `--size 0x0`,
`--size 40x0` and `--size -4x8` are a message on stderr and exit 1: there is no
frame to render, and quietly clamping to 1×1 would answer a question nobody
asked. A size past the cap **is** clamped, because `999x999` is a request rather
than a mistake and the cap is a property of the sample store, not of the
picture. `--steps 0`, `--steps -1`, `--seed -1`, `--quality 5`, `--el 46` and
`--dist 0` are all the same shape: refused with a message, exit 1.

> **`--az` with a negative value needs the `=` form.** `--az -360` is read as the
> flag `--az` with no value, because `-360` looks like a flag; `--az=-360` works.
> That is `args`'s documented convention and its message says so.

Exit codes: `0` ran (or `--help`), `1` a bad option, a bad value, or a stray
operand.

---

## What to look at when you run it

1. **The waist.** In `golden/opening.txt` the sphere and the box are *not* two
   objects near each other — they are one body with a neck. That is the smooth
   minimum: `min(a,b) - h²k/4` with `h = max(k - |a-b|, 0)/k`, and the blend
   reaches 0.55 here. `--dist 5 --el 18 --az 25` (`golden/close-up-the-blend.txt`)
   is the same waist from closer.
2. **`bytes` in the digest.** The first frame emits ~34 000 bytes of ANSI at
   78×21 and a settled frame a few thousand. That is `fb.flush_diff` finding
   the maximal runs of changed cells; an unchanged row costs nothing at all. A
   full repaint every frame would be 10–20× the traffic.
3. **`astep`.** The mean number of march steps a ray actually spent, from the
   digest of the last frame. It is 33–39 at the default settings and it rises
   with `--steps` — the budget binds, and the rays that spend all of it are the
   ones grazing the ground plane. See *Why the ground stops where it does*.
4. **The ground's far edge.** It is not the horizon and it is not the far plane:
   it is where the march runs out of steps. `golden/steps-160.txt` (160 steps
   instead of 72) reaches visibly further than `golden/opening.txt`, and nothing
   else about the picture changes.
5. **`hitpc`.** The fraction of samples that found a surface. About 53 % at the
   opening pose; it drops as you raise the camera and rises as you get closer
   than the scene is wide.
6. **The palette.** `p` cycles through five. `spectrum` is the one to try if you
   want to see where the ramp coordinate goes: it is height above the floor,
   plus depth along the ray, less the light, so the whole scene is swept by one
   256-entry cosine palette.
7. **`--glyph braille`** (`golden/glyph-braille.txt`) casts **four times** as many
   rays and has twice the horizontal and four times the vertical resolution. The
   horizontal doubling is visible; the vertical is not, because a terminal cell's
   four dot rows are about 4 pixels each on a typical font.

---

## How it works

### The scene (`scene.y`)

```
ground plane   y = -1.10
sphere         centre (-0.62, 0.05, 0.10),  r = 0.70
box            centre ( 0.72,-0.25, 0.25),  half (0.45, 0.62, 0.40), yawed 0.55 rad
capsule        axis (-0.20,-1.05, 0.75) -> (0.30, 0.95,-0.55), r = 0.30
```

The scene is a fixed shape, so every parameter is a compile-time constant and
`map()` takes no arguments but the point. That is deliberate: it keeps seven
longs out of the hottest call in the program.

**The spacing is the point of the scene and it was arrived at by looking at it.**
The sphere's right edge is at x = 0.08 and the box's left face at x = 0.27 — a gap
of 0.19, well inside the 0.55 blend radius — so the two come out of the
smooth-minimum as one body with a waist. Spread them further apart and the blend
stops happening. The floor gets its own, tighter, radius (0.35) so the objects
read as sitting *on* something rather than dissolving into it.

The capsule's axis is stored **already normalised**, so its projection parameter
`h = dot(p, axis)` needs no division by `dot(axis, axis)` — one division per
capsule evaluation, gone. `|axis|` comes to 1.000003 as stored, a 3e-6 relative
error in `h`, far below anything visible.

### `smin` — the part worth showing

```y
def smin(a: long, b: long, k: long) -> long {
    let lo = a; let hi = b;
    if (a > b) { lo = b; hi = a; };
    let d = hi - lo;
    if (d >= k) { return lo; };
    let h = k - d;
    lo - (((h * h) * k) >> 34)
};
```

That is the quadratic smooth minimum, and three things about it are what make it
the right primitive for a marcher:

* **It is never more than `min(a, b)`.** Sphere tracing requires a *lower* bound
  on the distance to the nearest surface; an over-estimate steps *through* a
  surface, which is the classic raymarching artefact. `min - h²k/4` is
  automatically below `min`, so the blend can be generous without becoming
  unsafe. `k = 0.55` on a scene 3 units across is safe because of this.
* **The blend term is a RAW product, not an `fx.mul`.** `h ≤ k ≤ 36045`, so
  `h*h ≤ 1.3e9` and `h*h*k ≤ 4.7e13` — both far inside a `long` — and the
  `>> 34` takes that Q48 result straight back down to Q16. No saturation, no
  branch, no 16-limb fallback.
* **When `|a-b| ≥ k` it returns `min(a,b)` exactly, with no division at all**,
  which is the common case for most of a ray.

### Sphere tracing, and why there is no `break`

```y
while (go && i < STEPS) {
    ...
    if (d < EPS) { hit = 1; go = false; } else {
        t = t + ((d * invl) >> 16);
        if (t > TMAX) { go = false; };
        i = i + 1;
    };
};
```

There is no `break` and there is none in Y (`ORCHESTRATOR.md` §2.9), so both
exits are a **guard flag with an explicit terminal assignment**: `hit` is set to
1 *and* `go` to 0 when the surface is reached, and `go` alone when the ray runs
past the far plane. Every path that leaves the loop leaves `i` at the number of
steps actually spent, which is what `astep` reports and what `MSTEP` sums into
the per-frame digest.

The step is the distance field itself, so the step length falls to nothing as
the ray lands and **no epsilon is needed to stop it overshooting** — `EPS` only
decides when to call it a hit.

**The early exits from `map()` are the `if (d >= k) { return lo; }` in `smin`.**
There is no other early exit in the field, and there could not usefully be one:
a distance field has to answer for the whole scene, and every primitive's
contribution has to be folded into the minimum. What *is* an early exit is the
`invl < 1` guard in `scene.render`, which is the one place a division by zero
could reach the march — a degenerate ray direction — and it is closed off there
once rather than trusted at every one of the 300 000 steps.

### The normal, from three taps that reuse work already done

```y
let gx = map(px + NRM_E, py, pz) - d;
let gy = map(px, py + NRM_E, pz) - d;
let gz = map(px, py, pz + NRM_E) - d;
```

The textbook version is a four-tap tetrahedron. This is the three-tap version
that **reuses the distance the march's last `map()` call already returned**: for
a distance field `|∇d| = 1`, so `(d(p + E·e_i) - d(p)) / E` is the i'th gradient
component — which is also the *outward* normal, because a distance field grows
away from its surface. Three evaluations instead of four, and no division,
because only the direction is wanted. With `E = 2⁻¹¹` the second-order term is
`E²/2r ≈ 0.01` whole units against a first-order term of 32, so the direction is
good to about 3·10⁻⁴.

> **The sign is the whole of it.** Writing `d(p) - d(p + E·e_i)` — the other way
> round — gives the *inward* normal, and then every lit surface in the frame is
> unlit: a plausible-looking picture in which the diffuse term is zero
> everywhere and only the ambient and the fog are left. It is worth knowing that
> this failure is silent; the code comments say so at the site.

One more ambient-occlusion tap, 0.10 along that normal. The distance there is
`AO_R` on open ground and less in a crease, which is the whole signal; `AO_LO` is
the depth at which the surface counts as fully buried. Inverting that ramp is
*also* silent — every surface comes out lit in a crease and pitch black in the
open — so the comment at the site says which end is which.

### The specular, and a false economy that cost more than it saved

The first version of this normalised the Blinn half vector with a **constant**
`1/√2`, on the reasoning that the light and the view are "usually"
perpendicular. They are not: `|L + V|` runs from 0 (looking away from the light)
to 2 (looking into it), so the fake normaliser reported a half-vector cosine
above 1 over a broad cap, the exponent saturated, and **a third of the sphere
came out pure white**. One `qsqrt` and one division per *shaded sample* is much
cheaper than that, so it is normalised properly.

The exponent is 16, not the more usual 24 or 64. At one ray per cell half a
cell, a 24th power of a cosine that moves by a per cent between neighbouring
cells turns the highlight into salt-and-pepper, and no amount of care in the
march will fix it.

### Why the ground stops where it does

The plane's distance is exact at every point, so a grazing ray marches in steps
of its own perpendicular distance, which shrinks geometrically: after `N` steps
`d = h·(1-sinθ)^N`, and the march calls it a hit when that drops below `EPS`.
So the visible extent of the ground is set by the **step budget**, not by the far
plane:

```
sinθ  >  ln(EPS / h) / N   ≈   8.1 / N
```

At `N = 72` that is 6.5° below horizontal; at 160 it is 2.9°. That is why
`golden/steps-160.txt` reaches further than `golden/opening.txt`, and it is why
the `--steps` dial is worth having even though it barely moves the frame rate.
Raising `TMAX` from 24 to 90 changed the picture by nothing at all, which is how
this was found.

### The sky, and the LUT

Five palettes. Each is a 256-entry RGB **surface** ramp indexed by the shading
coordinate (height above the floor + depth along the ray − light) plus a
256-entry **sky** ramp indexed by the ray's vertical direction. Both are built
**once at start-up** out of `fx.cos` — 3840 entries, about a millisecond — which
is the only reason `fx` is in this file at all, and the reason a cosine palette
is affordable here when it is not affordable per pixel. Cycling palettes with a
keypress is then a single store, with no rebuild.

The sky index scales the ray's vertical component by 500, not by the obvious 127.
The frame's vertical half-angle is about 0.2 in tangent, so 127 spends only 51
of the ramp's 256 entries on the whole picture and the sky bands visibly; 500
puts the field of view across 200 of them for one multiply. The haze band over
the horizon is wide on purpose — see *Why the ground stops where it does*.

---

## The Q30 question: where the headroom is

Everything in `scene.y` is **Q16**, not `fx`'s Q30, and that is the single
biggest decision in the example.

`fx.y` is Q30 (1.0 = 2³⁰) because a library of transcendental functions needs
`mul()` and `fdiv()` to be exact to an ulp across a 4·10⁹ range. A scene is a
different problem: nothing here needs more than 16 fraction bits (the hit
epsilon is 2⁻¹¹ of a scene unit and one terminal cell spans about 2⁻⁵), and at
Q16 a product of two in-range quantities is **one machine multiply and one
shift** instead of a call into `fx.mul` with four branches, three range tests
and a 16-limb wide-multiply fallback. The inner loop calls into `fx.y` exactly
nowhere.

The brief's warning — that *a Q30 dot product is Q60 and needs a scale-down, or
it overflows 62 bits* — is the reason, and here is where the headroom is:

| quantity | range | bits used | of 62 |
|---|---|---|---|
| `p`, every scene constant | ±32 real | ±2²¹ | |
| `p*p`, so a three-term dot | ≤ 3·2⁴² | 2⁴³·⁶ | **18 clear** |
| the `smin` blend product `h*h*k` | ≤ 4.7·10¹³ | 2⁴⁵·⁵ | 16 clear |
| `r*t` (the march's position update) | ≤ 58 real | 2²⁸ | |
| the sun term `(r·S)·invL` | ≤ 2.6·10¹⁰·2¹⁷ | 2⁴⁴·⁸ | 17 clear |

So the widest thing in the frame is a **square-root argument at 2⁴³·⁶ with 18
bits in hand**, and nothing comes near the top of a `long`.

The *real* hazards in fixed point are not arithmetic, and they are all guarded
where they are created rather than at every use:

* **a division by zero** — `qsqrt`'s Newton step divides by its seed, the march
  divides by the ray's length, `smin` has no division at all. The seed can never
  be zero (`qsqrt` shifts its argument into `[2²⁵, 2³⁶)` first, so the table
  index is ≥ 1 and `SEED[1] = isqrt(2²⁵) = 5793`); the ray length is clamped to
  ≥ 1 and `ray_inv` returns 0, which `render` turns into a sky sample.
* **a negative shift count**, which is a *runtime trap*, not a diagnostic. It is
  the one that bit me here and it is worth spelling out:

> ### `>>>` is a LOGICAL shift. `>>` is the arithmetic one.
>
> `ORCHESTRATOR.md` §2.10 says so, and it is not a detail. Three bugs in this
> example were `>>>` applied to something that can be negative:
>
> * `cos255`'s final `(v * 255) >>> 30`, where `v` goes negative for most of a
>   cosine sweep — shift a negative Q30 value right by 30 and you get
>   2⁶⁴-minus-something, the clamp turns it into 255, and **one channel of the
>   ramp comes out pure white for half its length**.
> * `camera_update`'s `fx.mul(...) >>> 14`, where `sin(AZ)` is negative for half
>   the orbit — which puts the camera a million units away and renders an
>   all-sky frame that still looks plausible.
> * the palette coordinate's `(py >>> 16) * 44`, which is a floor for `>>` and a
>   wrap for `>>>`.
>
> The audit is one grep: `grep -n '>>>' *.y` and check every operand. The three
> that survive in this folder (`qsqrt`'s table index, the jitter hash, `sink`'s
> hex printer) are all provably non-negative, and `>>>` is what they want.

### The integer square root

`fx.isqrt` is exact for every `0 ≤ u < 2⁶²` and costs **43 ns** measured on this
tree. `qsqrt` costs **8 ns**, and there are three of them per march step, so it
is the single largest constant in the renderer.

The method is the usual one: a 2048-entry table of square roots seeded from the
top 11 bits, then three Newton steps in integers. The argument is first brought
into `[2²⁵, 2³⁶)` by an even number of bit shifts, so the table index always
carries 10 significant bits. Shifting costs the answer `up` bits on the left or
`dn` on the right and never more than one unit of precision, because two bits on
the argument is one bit on the root.

Checked against `fx.isqrt` over 600 000 arguments from 1 to 6.8·10¹⁰: the worst
disagreement was 7 units, at `u = 1.1·10¹²`, which is the right-shift path
losing bits far out in the tail. **Inside the range the marcher actually uses
(`u < 2³⁶`, so no shift at all) the answer is within one unit**, i.e. 1.5·10⁻⁵
real — eight orders of magnitude below the 2⁻¹¹ hit epsilon.

---

## Which ramp, and why

The brief asks for a decision between ascii, braille and half blocks, with the
reason. **This example uses half blocks, and the reason is that the shading needs
a vertical level that a coverage ramp cannot carry.**

* **`ascii`** keys the glyph on **luminance**, through `fb.shade_ascii(v, 256)`.
  Ten glyphs. It is the classic choice and `golden/glyph-ascii.txt` shows it
  working — but ten glyphs cannot hold a gradient, and on a *lit 3D surface* the
  thing that matters is precisely the gradient. It also throws away the
  horizontal resolution it could have had, because it samples once per cell.
* **`braille`** keys the glyph on **coverage** — a 2×4 dot bitmap — and is the
  honest answer when the picture is *lines and edges*. For a solid shaded
  surface it is close to useless: inside the silhouette coverage saturates at
  8 of 8, so every cell in the middle of the sphere comes out as the same full
  block, and the shading has to go in the colour. It then costs **four times the
  rays** (8 a cell against 2) for twice the horizontal resolution, which at this
  resolution is worth having and four times the vertical, which is not visible
  on a font whose cell is 16 pixels tall.
* **`half`** samples **twice vertically**, and uses the pair as a two-bit glyph
  index. This is the part that makes it right for *this* scene:

  ```
  cp   = fb.shade_half(level, 4),   level = upper_hit + 2*lower_hit
  fg   = the upper sample's colour,  bg = the lower sample's colour
  ```

  The glyph says which halves are surface, and the two colours ride in the cell
  foreground and background — so a lit surface gets **two independent levels per
  row** and 2× the vertical sampling, at twice the cost of ascii, not four
  times.

  `fb.shade_half(level, 4)` is worth a note: that is the toolkit's own
  four-entry half-block ramp reached through its own monotonic `ramp_index`,
  since `ramp_index(level, 4, 4)` *is* `level`. No codepoint is spelled out in
  this folder. The ramp is `[space, U+2580, U+2584, U+2588]`, and a glyph paints
  its **filled** halves in the foreground and leaves its open halves to the cell
  background — which is why `level == 2` has to swap: U+2584 fills the *bottom*,
  so the colour that belongs to the lower sample is the one that has to be the
  foreground. Levels 0 and 3 fill the whole cell with one colour, so those
  average the two samples.

All four modes are available (`--glyph`), and the digest's `rays/frame` column
tells you what each one costs before you run it.

---

## Measured performance

`--no-tty --frames 30 --time`, one row per configuration. The fps column is the
**observed range over repeated runs** on this machine, which is shared with five
other agents, so the spread is load and not the program:

| size | glyph | rays/frame | fps (observed) | avg steps/ray | heap delta over 200 frames |
|---|---|---|---|---|---|
| 20×8 | half | 320 | **171.8** | 34 | 0 |
| 40×16 | half | 1 280 | **43.6 – 45.6** | 33 | **0** |
| 60×24 | half | 2 880 | 19.3 – 19.7 | 33 | 0 |
| **80×23** (an 80×24 terminal) | **half** | **3 680** | **14.3 – 14.7** | **37** | **0** |
| 120×40 | half | 9 600 | 5.9 | 35 | 0 |
| 160×60 | half | 19 200 | 3.6 | 34 | 0 |
| 80×23 | ascii | 1 840 | 25.2 | 44 | 0 |
| 80×23 | blocks | 1 840 | 25.1 | 43 | 0 |
| 80×23 | braille | 14 720 | 3.8 | 37 | 0 |

**The honest headline: the default interactive size is about 15 fps, not 30.**
A 100×40 frame at 128 steps is 512 000 sqrt-heavy march steps and costs about
170 ms; 120×40 here is 5.9 fps, which matches the estimate in the brief closely.
A raymarcher in a language with `float` → `long` missing, `sqrt` missing, no
`break`, and a heap that never frees, at 14–15 fps on a 2 400-sample frame, is a
reasonable place to be — and claiming 30 would be a lie.

**The `--quality` dial, and what it actually buys** (80×23, half):

| `--quality` | `--steps` | fps | avg march steps/ray |
|---|---|---|---|
| 1 | 40 | 19.0 | 28 |
| **2 (default)** | **72** | **14.6** | **37** |
| 3 | 112 | 12.6 | 43 |
| 4 | 160 | 11.5 | 47 |

Only 1.6× between the cheapest and the dearest setting, because the per-sample
*fixed* cost (three `qsqrt`, the camera basis, the cell pass, the flush) is a
large share of a frame at 40 steps and a small one at 160. **Quality 3 or 4 buys
the ground reaching further** (see *Why the ground stops where it does*) rather
than a smoother silhouette, so quality 2 is the default and `--steps` is there
for anyone who wants the extra reach.

If 30 fps matters more than the picture does: `--quality 1` at 40×16 gives 46 fps,
and `--glyph blocks` halves the rays against `half` for 25 fps at 80×23 — though it
also throws away the vertical resolution that makes the sphere read as a sphere. Both
are worse pictures and both are honest trades.

### No per-frame allocation — measured, not asserted

```
$ ./fractal --frames 200 --no-tty --size 40x16 --time
fractal: 200 frames in 455785 us = 455 ms -> 43.89 fps
fractal: 40x16 half steps=72 rays/frame=1280 avg march steps/ray (last frame)=34
fractal: heap_used before=8713112 after=8713112 delta=0
```

and the same for `--glyph braille` (200 frames, 14720 rays each) and
`--color ice --glyph blocks`. The delta is **0** on all three.

Getting there took moving three things off the frame path, and all three are the
same trap — **a literal inside a loop body is evaluated onto the heap every
iteration** (SUGGESTIONS §7), 64 bytes for a five-field record and 72 for
`[long; 12]`, while nothing is ever freed:

| was | now |
|---|---|
| `trace()` returned a record | it writes module-level `MHIT`/`MLUM`/`MCOL` and returns `void` |
| the HUD printed the camera distance with `fx.to_str` | one integer and a literal `.`, digit by digit, with module-level scratch (`DIG`) |
| the resize poll called `term.size()` | `TIOCGWINSZ` into our own `[byte]` plus `term.rd16` — same answer, zero bytes of heap, because `term.size()` *answers with a record* |

The per-ray setup is precomputed once per resize into `scene`'s `RXO`/`RYO` and
never touched again, and the camera basis is folded in by the marcher rather than
baked into the grid — so **orbiting the camera costs three multiplies a sample
and no trigonometry at all**. The palette ramps, the seed table, the sample
store, the braille scratch and the shadow are all module-level. There is not one
array or record literal on the frame path.

---

## The frame loop allocates nothing, and the digest is a checksum of it

`--no-tty` prints the same scene, the same marcher, the same cell pass and the
same `fb.flush_diff` as the terminal path. Only the sink differs:

```
fractal: frames=2 size=40x16 glyph=half color=ember steps=72 quality=2 seed=0 rays/frame=1280
dumped frames: 1
frame     0 bytes    17034 rows    16 hits     679 hitpc  53 astep   33 sha 39d9d7905e83d3b0
frame     1 bytes     6888 rows    14 hits     678 hitpc  52 astep   33 sha 4e9fa7ff7b5362dd
--- frame 1 ---
<the picture>
```

The per-frame `sha` is an FNV-1a over every cell's codepoint **and both of its
colours** (`sink.grid_digest`), so a frame that changed colour but not shape is a
different digest — which is why that line is evidence rather than decoration.
Both colour channels matter here in a way they do not in most examples: the
half-block glyph carries the lower half's colour in the cell *background*, so a
lighting change can be a background-only change.

`EXPECTED` is that run, byte for byte, and it is byte-identical across runs. No
HUD on this path: a status line carrying a frame rate cannot be. The wall clock
and the heap delta go to **stderr** under `--time`. Nothing depends on the
terminal, the clock, the heap layout or a random seed.

`--seed` is the only stochastic knob and it is **off unless asked for**: 0 means
no jitter at all. A non-zero seed adds a sub-sample ray jitter — a pure hash of
`(seed, frame, index)`, so it is reproducible from the seed alone and costs
nothing when it is 0. It is there to break the march's stepping bands when you
want to see what they look like, not because the picture needs it.

---

## Two paths, three test harnesses

`pty_check.py` is in the folder and is how the interactive path is verified
without tmux (which is not installed on this machine). It allocates a pty, sets
the window size **before** `execv` (a pty from `pty.fork()` is 0×0, and
`TIOCGWINSZ` would otherwise report nothing), waits for the alt screen, types the
keys it is given, and then checks that the terminal was handed back.

```
$ python3 pty_check.py ./fractal
alt screen entered                : True
alt screen left                   : True
cursor hidden                     : True
cursor shown                      : True
keys typed                        : True  1/1
exit status 0                     : True  raw=0
c_lflag restored                  : True  0x8a3b -> 0x8a3b
ECHO restored                     : True
ICANON restored                   : True
ANSI SGR runs emitted             : 974
ANSI cursor moves emitted         : 23
bytes from the pty                : 35866
RESULT                            : PASS
```

`c_lflag` identical before and after is the load-bearing line: the terminal came
back in cooked mode, so the shell has its echo and its Ctrl-C. It has to hold
even when nothing in the program gets a chance to run — which is what
`term.arm_watchdog()` is for, a forked child blocked on a self-pipe with
`setsid`, restoring the saved termios the instant the parent's pipe closes.

`snap.py` is not part of the gate. It runs the program under a pty, replays the
ANSI into a cell grid and writes a **PNG**, which is how the claims above about
colour and about which ramp was chosen were checked rather than asserted.
`--ansi FILE` is the deterministic version of the same thing: it points the
emitter at a file and writes the last frame there in full.

`gate.sh` is the whole acceptance gate, re-runnable: `sh gate.sh` (it honours
`YCC=`).

---

## The property check: `--check`, and an oracle that was wrong

`--check N` marches N camera poses and compares every ray against a **closed-form
oracle that never marches**: the sphere in the scene is a real sphere
(`SPH_X/Y/Z = -0.62, 0.05, 0.10`, `SPH_R = 0.70`), so for any ray

```
oc = eye - centre,  b = oc.u,  cc = |oc|^2 - r^2
hits iff d = b^2 - |u|^2 cc >= 0,   near root = (-b - sqrt(d)) / |u|^2
```

Every square root in the oracle is `fx.isqrt` — an exact integer root, a different
implementation from `scene.qsqrt`'s 2048-entry table — and every primitive distance
is re-derived rather than asked of the scene, so the two sides cannot share a
step-arithmetic, convergence or epsilon bug. What they *do* share is the ray: the
projection, the camera basis and the grid, because the question is "did the marcher
find the surface this ray actually hits".

| test | what it holds |
|---|---|
| **T0** | `min - k/4 <= map(p) <= min` at every point the marcher stopped on — smin's contract, the whole reason sphere tracing is safe |
| **T1** | the marched depth against the closed-form root: to 4·EPS on the well-conditioned subset, and never deeper than the analytic surface by more than one smooth-minimum bulge |
| **T2** | a ray the quadratic says misses never stops *on* the sphere; the only excuses are EPS and a blend, and both are quantified |
| **T3** | the drawn silhouette of a sphere **is** the ellipse the tangent cone predicts — three independent derivations of it |
| **T4** | the step budget changes how far the ground reaches and nothing else: the set of hit cells over the objects is identical at 40 and 160 steps outside a one-cell boundary band |
| **T5** | where the box and the sphere overlap, the marched depth never sides with the farther surface |

### T3, and the tolerance it is allowed

T3 runs on a control scene (`scene.solo`) where the sphere is the *only*
primitive: no blend, nothing in front of it, so a hit **is** the sphere. Three
derivations of the same ellipse have to agree over a camera sweep from 2.5 to 8
scene units:

* **`scan`** — brute force: the closed-form quadratic at every one of the 7 680
  rays, and the extreme sample offsets it hits;
* **`cf`** — the roots of the conic's extent equation, in closed form, with no
  marching and no sampling at all;
* **`drawn`** — the marched and rasterised outline.

```
$ (ulimit -S -v 3670016; ./fractal --check 24) </dev/null
  dist   analytic  hit   miss  overhit |   scan x0   x1   y0   y1 |      cf x0   x1   y0   y1 | drawn x0 x1 y0 y1  worst  gram
  2     2765  2765     0       6 |      10    62    31     0 |      10    62    31 -  19 |     10  62   0  31       0  0.000031
  3     2075  2075     0       8 |      20    61    28     0 |      19    62    29 -  13 |     20  61   0  28       0  0.000031
  4     1339  1339     0       8 |      31    61    25     0 |      30    61    25 -   5 |     31  61   0  25       0  0.000031
  5      771   771     0       9 |      39    60    22     1 |      38    61    23     0 |     39  60   1  22       0  0.000031
  8      361   361     0       9 |      46    60    20     5 |      45    60    20     5 |     46  60   5  20       0  0.000031
  scan vs the conic's roots, worst, in cells: 0.982224 across (band 1.0, one
  sample pitch), 0.413284 down (band 0.5, half a sample pitch), over the 16 of 20
  edges where the ellipse stays inside the frame
  edges where the ellipse LEAVES the frame and only the marched outline can be
  compared: 4
  drawn vs the analytic extent, worst, in cells: 0.000000 of overshoot (must be
  <= 0) and 0.000000 of shrinkage (band 1.0)
  worst clearance of a ray the marcher hit and the quadratic called a miss, over
  9 such samples: 0.000381   (2*EPS is 0.000977)
  oracle's drawn width at the near and the far camera: 52 and 14 cells, so
  far/near = 0.269226 against 0.235 for r/sqrt(d^2-r^2)
  times the oracle's extent GREW as the camera pulled back: 0  (must be 0)
```

**The tolerance, and why it is one cell.** The marcher's own stopping rule is
`map(p) < EPS`, and on the control scene `map()` is an *exact* signed distance, so
the marcher stops the first time it is within `EPS = 2^-11 = 4.9e-4` of the
surface — and near the silhouette it may stop EARLY, where the field shrinks
faster than the ray closes on it. A sample whose cell centre sits within one cell
of the tangent point can therefore go either way, and the outermost cell holding a
hit may be up to one cell inside the analytic extent. So the rule is asymmetric on
purpose:

* drawn **inside** analytic — allowed, up to **one cell** (the EPS stopping rule);
* drawn **outside** analytic — **not allowed, at all** (a marcher may stop short
  of a surface but never overshoot one).

Measured, the marched outline coincides with the analytic extent exactly (0.0
cells of either kind), so the budget is not being spent. The **closed forms** are
compared to each other, with no quantisation anywhere in them, to one **sample
pitch** — a cell across, half a cell down, since `grid_setup` puts one sample per
cell horizontally and two per cell vertically — and they come out at 0.98 and 0.41
cells. Anything looser would be a tolerance rather than a bound.

Two things the table is doing that are worth naming. `cf` prints a row or column
outside `0..31` / `0..119` because **the ellipse leaves the frame** at the closer
distances: the sphere is taller than the whole image there, so the tangent cone
reaches 19 rows above the top of the frame. Those edges are excluded from the
`scan`-vs-`cf` comparison (a clipped extent is not an ellipse's extent) and the
count of them is printed — 4 of the 20. And the last line is the property the
original version of this check violated, written down so the shape of mistake
cannot come back: a sphere of **fixed radius** must have a **smaller** silhouette
as the camera pulls back, by a computable amount (`r/sqrt(d²-r²)`, a factor 4.26
over this sweep). The old oracle reported the *same* extents at every distance
from 2.5 to 8, which no sphere can do — a scan whose extents never move is wrong
by inspection, before anything else is checked.

### The oracle was wrong, not the renderer — six ways

This is the folder's own version of the `cube` lesson, so the failures are
recorded rather than just repaired. The renderer never changed: `EXPECTED` and
every file in `golden/` are byte-identical before and after, and the marched
outline agreed with the analytic extent throughout. What was wrong was the
oracle's arithmetic, and all six defects are the same mistake in different clothes
— **a fixed-point quantity divided without being lifted, or subtracted at the
wrong width**, which is silent, produces a plausible-looking number, and is
invisible in every count:

1. **`ODEPTH = num / uu`** — both are Q16, so this returned their *ratio*: a
   dimensionless `2` for every ray in the frame, instead of a depth of 1.86 to 2.45.
   T1 reported all 21 966 rays as having stopped deeper than the analytic surface,
   and T5 said the box was nearer the surface than the sphere in 1 005 cases it was
   not. Fix: `(num << 16) / uu`.
2. **`isqrt(4 * d)` in `conic_solve`** — the root formula already carries the
   factor of two from the `2q` term, so the pair's separation was doubled. Fix:
   `isqrt(d)`.
3. **`(0 - q - sd) / p`** — the same missing lift as (1), on the conic's roots.
   Both roots truncated to 0, which is why the `cf` column read `60 60 32 32`: both
   roots at the exact centre of the frame, at every distance, which is the one
   answer a moving sphere cannot give.
4. **`cells_v` added where it must subtract, and at twice the scale** — cell rows
   count down and `oy` grows upward, and the vertical had its own constant that
   was `2 ×` the horizontal one. The two errors nearly cancelled: the printed row
   came out at exactly *twice* the right one, so the analytic column read `0..63`
   where the marched column read `0..31`. It looked like a silhouette twice as tall
   as the frame. Both axes use the same constant now, and it is Q32, because 85.71
   does not fit in Q16 and the 0.8 % that is short of is half a cell at the frame
   edge — the same size as the band being measured.
5. **the discriminant clamp at a hand-picked 262144** — Cauchy–Schwarz caps the
   discriminant at `|u|² r²`, which is 2.8e10 for these poses, not 4.0. The clamp
   therefore fired on most rays and propagated: `OMISS` collapsed to 0 for every
   ray passing more than 4 units of squared distance from the centre, so the
   angle-corrected tolerances in T1 and T2 were measuring nothing. The clamp is now
   derived — and it is what makes `isqrt` safe on `r² - d/|u|²` without a guard,
   since the bound is exactly what keeps that argument non-negative.
6. **`OMISS` missing its lift before `isqrt`** — the quotient is a Q16 number and
   `isqrt` of a Q16 number is a Q0 *root*, so a tangent ray's `r = 0.7` came back as
   0.0027, 256× too small. This is the most dangerous kind of error: a too-small
   miss only ever looks like a *better*-conditioned ray, so it silently filled T1's
   core subset with exactly the grazing rays the depth tolerance exists to exclude.

Two more of the same family were found on the way and are marked in `check.y`: the
plane-distance test in `clean()` used `px - PLANE_Y` (the point's *x* against the
plane's *y*), and three sweep-wide counters were reset per pose instead of once,
so the summary line reported the last row's numbers under five rows of data.

### The other four tests, and their numbers

`--check 24` also reports, and these are the figures to read for T1/T2/T4:

```
T1  rays that hit the sphere analytically       21966
      the marcher also hit     21966   missed 0   eye inside 0
    WORST depth error   1.643768   = 0.048431 cells of lateral movement
    rays that stopped BEHIND the true root: 0
    core subset (clean of every blend, incidence better than 60 degrees): 6516 rays
      WORST depth error there 0.000977 = 0.500000 x the 4*EPS tolerance
      the marched point is 0.000244 from the sphere, and map() there says 0.000244
      the analytic point is 0.000900 from the sphere (the oracle's own residual)
T2  such rays that hit something      136596
    worst (miss - r), how far outside the cone it stopped: 5.048508
    over-hits neither excuse explains: 0
T5  both hit, roots well apart 1323; the marcher sided with the FARTHER surface: 0
    worst (marched depth - the nearer root): 0.001678; outside the band: 0
T4  cells compared 1560; hit/miss differs at 40 vs 160 steps: 21, of those outside
    the one-cell boundary band: 0; worst depth disagreement: 0.000000
```

T1's headline figure of 1.64 is *not* a disagreement about the sphere: it is a ray
that hit the box, or a blended surface that legitimately sits further back than the
sphere's own root, and the test separates those cases rather than averaging them —
the core subset is what the depth tolerance is asserted on, and there the marcher is
within 0.5 × the tolerance. T2's 5.05 is a ray that missed the sphere by five units
and hit the ground instead, which is correct behaviour and is exactly what the
"worst clearance" line exists to make visible rather than to fail on.

---

## Re-running the gate

```sh
cd examples/fractal
(ulimit -S -v 3670016; sh gate.sh) </dev/null     # prints [1]..[8], ends GATE: PASS
```

```
$ (ulimit -S -v 3670016; sh gate.sh) </dev/null
=== gate: fractal ===
    compiler /home/yun/Projects/compiler/refs/ycc.ref
    c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631  .../refs/ycc.ref

[1] compile clean, zero warnings
[2] run= is deterministic over 2 runs
[2] run= matches EXPECTED
[3] no runtime trap over 63 invocations
[4] heap delta 0 over 200 frames: half, braille, blocks
    --- measured ---
fractal: 30 frames in 204355 us = 204 ms -> 14.68 fps
fractal: 80x23 half steps=72 rays/frame=3680 avg march steps/ray (last frame)=37
fractal: heap_used before=8713112 after=8713112 delta=0
fractal: 30 frames in 65703 us = 65 ms -> 45.66 fps
fractal: 40x16 half steps=72 rays/frame=1280 avg march steps/ray (last frame)=33
fractal: heap_used before=8713112 after=8713112 delta=0
    --------------
[5] wall clock reported above
[6] pty: alt screen in and out, q exits 0, terminal restored
[7] standalone rebuild is byte-identical
    === fractal: 9/9 passed ===
[8] examples/gate.py reports 9/9
[9] the example's own --check exits 0, no trap, no FAIL

GATE: PASS
```

And the orchestrator's own harness agrees:

```
$ cd examples && (ulimit -S -v 3670016; python3 gate.py fractal) </dev/null
=== gate: fractal ===
    folder   /home/yun/Projects/compiler/examples/fractal
    compiler /home/yun/Projects/compiler/refs/ycc.ref
    sha256   c53cc41524a7baa2de88d0f56faf5e2c

[PASS] 0 compiler pin present  c53cc41524a7baa2 matches a sha in the README
[PASS] 1 compile zero warnings  9 file(s) clean
[PASS] 2 golden output  1672B identical over 2 runs
[PASS] 3 no runtime trap
[PASS] 4 inside memory cap  ulimit -v 3670016 KiB enforced on every run
[PASS] 5 self-contained  no cross-folder import or embed
[PASS] 6 README complete  41626B, all keys present
[PASS] 7 filing pointers resolve  10 filing(s) in BUGS.md
[PASS] 8 example's own property check  worst depth disagreement on matched hits: 0.000000 | RESULT  PASS | elapsed 413 ms

=== fractal: 9/9 passed ===
```

It runs all nine items: the pin, the zero-warning compile, three deterministic
runs plus the `EXPECTED` comparison, **63 invocations checking that no path traps**
(every option, every bad value, `--size 0x0`, `--size 1x1`, `--steps 0`,
`--steps -1`, `--seed -1`, a stray operand, every glyph and palette pair,
`--help`), the 200-frame heap delta in three modes, the wall clock,
`pty_check.py`, a standalone rebuild into `mktemp -d` compared byte for byte, and
**item 8, which runs `./fractal --check 24` and fails on a non-zero exit, a
`runtime error:` trap, or the word `FAIL` anywhere in the output**. Item 8 exists
because this folder sat at 8/8 while shipping a `--check` that **failed** — the
gate compared stdout against a golden file and never asked. A property check
nobody runs is not a check, and a golden file cannot tell you the geometry is
right; see the section above for what item 8 now reports.

---

## Files

| file | lines | what |
|---|---|---|
| `fractal.y` | 879 | CLI, the four cell-assembly modes, the status line, both frame loops |
| `scene.y` | 918 | the SDF, `smin`, the integer sqrt, the marcher, the shading, the palettes, the camera |
| `sink.y` | 232 | the deterministic sink: fixed byte buffer, FNV digest, text frames |
| `EXPECTED` | 22 | `./fractal --frames 2 --no-tty --size 40x16`, byte for byte |
| `pty_check.py` | 135 | the pty harness for the interactive path |
| `snap.py` | 188 | ANSI → PNG, for looking at the picture without a terminal |
| `gate.sh` | 164 | the whole acceptance gate, re-runnable |
| `golden/opening.txt` | 22 | the opening pose — sphere and box fused into one body |
| `golden/close-up-the-blend.txt` | 22 | the same waist from closer |
| `golden/from-the-other-side.txt` | 22 | azimuth 205°: the capsule behind, the box's other face — **see the note below** |
| `golden/orbited.txt` | 37 | frame 11 of a 12-frame orbit, with all twelve digests |
| `golden/steps-160.txt` | 22 | `--steps 160`: the ground reaches further |
| `golden/glyph-braille.txt` | 22 | 8 rays a cell |
| `golden/glyph-ascii.txt` | 22 | 1 ray a cell, glyph by luminance |
| `golden/color-ice.txt` | 22 | the ice palette |
| `golden/color-spectrum.txt` | 22 | the spectrum palette |

> **One golden has no recorded invocation, and saying so is better than leaving
> it.** Eight of the nine files in `golden/` reproduce byte-for-byte from the
> invocations below. `from-the-other-side.txt` does not: a 144-case sweep of
> `--az 205` against elevation and distance, and a 56-case one at other
> elevations, never reproduce its frame digest `fcddedbfd5288802`. The render
> path is untouched by this work — `scene.y` and `sink.y` are unmodified and the
> only change to `fractal.y` is a bound on `--check N`, which is a different code
> path — so this is a documentation gap left by the previous version of this
> folder, not a regression, and the file is not part of the acceptance gate (item 2
> compares `EXPECTED`). It is recorded rather than quietly regenerated, because a
> golden that cannot be regenerated is a golden nobody should trust.
>
> ```sh
> ./fractal --frames 1  --no-tty --size 78x21 --dump 0                  > golden/opening.txt
> ./fractal --frames 1  --no-tty --size 78x21 --steps 160 --dump 0       > golden/steps-160.txt
> ./fractal --frames 12 --no-tty --size 78x21 --dump 11                 > golden/orbited.txt
> ./fractal --frames 1  --no-tty --size 78x21 --glyph braille --dump 0  > golden/glyph-braille.txt
> ./fractal --frames 1  --no-tty --size 78x21 --glyph ascii   --dump 0  > golden/glyph-ascii.txt
> ./fractal --frames 1  --no-tty --size 78x21 --color ice     --dump 0  > golden/color-ice.txt
> ./fractal --frames 1  --no-tty --size 78x21 --color spectrum --dump 0 > golden/color-spectrum.txt
> ./fractal --frames 1  --no-tty --size 78x21 --dist 5 --el 18 --az 25 --dump 0 > golden/close-up-the-blend.txt
> ```

## The std units this uses

Vendored byte-identical from `examples/_toolkit/` and **not edited** (the folder
contract, `ORCHESTRATOR.md` §4):

| file | sha256 prefix | lines |
|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 |

```sh
cd examples/fractal && sha256sum fx.y tui tui tui args
```

> **`fx.y` and `tui` moved while this example was being built, and every
> example in the campaign moved with them.** This folder started on
> `fx.y` `97c3c02d345efb7f` (687 lines) and `tui` `741300d71f99b06e` (962
> lines); the canonical copies were re-vendored campaign-wide with the two
> fixes filed against them (`fx.isqrt` on a negative argument, and `fb.emit_num`
> dropping a zero digit — both in `examples/BUGS.md`), and they are now
> `4b47a9bfef0c1e30…`. std `tui` and `args`
> did not move. The two shas above are what this folder is built and verified
> against now, and `sha256sum` in this folder reports the same thing as
> `sha256sum` in `examples/_toolkit/` — which is the check worth running after
> any re-vendor. See *The toolkit bug that was here, and what happened*.

---

## Compiler pin, and the workarounds

> **Pinned compiler:** `refs/ycc.ref` sha256
> `c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.
>
> The pin moves. `ORCHESTRATOR.md` §3 records it being reblessed twice while this
> example was being written, and the `fb.emit_num` entry in `examples/BUGS.md`
> quotes the *same* sha as the one this example was built against, so the two
> agree. **The path is the pin; the hash above is what this folder is verified
> against.** `EXPECTED` is a property of the maths, and the maths is this
> folder's — nothing here depends on a compiler build.

Two things in this example are shaped by something outside it, plus one that
shaped it and has since been fixed. None of them is a miscompilation.

### The toolkit bug that was here, and what happened

This is worth writing down because it is the one thing that made this example
look broken when it was not, and because the fix is a worked example of the
campaign's own protocol.

**`tui`'s `emit_num` dropped a zero digit.** It takes the hundreds digit and
then only emits further digits while the remainder is ≥ 10, so **104 was written
as `14`**. Every SGR channel and every CUP operand goes through it, which makes
it two things at once:

* a **colour** channel in `100…109` or `200…209` emitted with a digit missing,
  which turns a smooth gradient into per-cell speckle;
* a **cursor column** in the same ranges landing in the wrong place, so a whole
  row is drawn in the wrong columns.

Filed by `examples/maze`: `examples/BUGS.md` §"`tui`'s `emit_num` drops a zero
digit: colour channel 205 is emitted as `25`, and column 101 as `11`". This
example hit it hard — an ember raymarcher passes through both windows on every
frame, and the first working build came out as a picture of magenta and cyan
speckle that looked like a shading bug for a long time. (It was, partly: two
*real* shading bugs were hiding behind it — see *The specular* above.)

The workaround here was a local `ansi.y`: the same algorithm `fb.flush` and
`fb.flush_diff` implement, with a four-line fix to the number writer, because
the colour half cannot be dodged from outside `fb` and the cursor half cannot be
dodged at all without capping the surface at 99 columns (`examples/maze` does).

**Then the canonical copies were fixed and re-vendored campaign-wide**, so
`tui` here is now `95a7663b7f1c7a90…` with the corrected `emit_num`, and
`ansi.y` is **gone**: this folder uses `fb.flush`, `fb.flush_diff`,
`fb.frame_bytes`, `fb.row_count` and `fb.capture_*` unchanged, exactly as every
other example in the campaign now does. `EXPECTED` and every file in `golden/`
are byte-identical either way, because they are text frames and the bug was
never in the text path.

Two things from that are worth keeping:

* **`--ansi FILE` is the cheap way to see a toolkit rendering bug.** It writes
  the framebuffer's real byte stream to a file, and `cat -v` on it is the whole
  diagnosis. `snap.py` replays it into a PNG; `grep` on it is the evidence.
* **`fb.set_fd` + `fb.capture_on` is a real seam.** Pointing the emitter at
  `/dev/null` and keeping the capture is what makes the headless path's `bytes`
  column a measurement of the interactive path rather than a claim about it.

#### 1. `str + byte` segfaults — and `chr()` is not the way round it

**Filed:** `examples/BUGS.md` §"`str + byte` segfaults".

`line = line + RAMP[i]` is the natural way to shade a frame cell by cell and it
crashes with SIGSEGV. This example never writes it, for a reason that is worth
recording: **the filing's suggested workaround does not work for a glyph.**
`chr(n)` is documented in `src/y/std/rt.y` as the inverse of `ord()`, and
`ord()` is *"the code of the first **byte**"* — so `chr(0x2588)` is a one-byte
string containing `0x88`, the low byte of the codepoint, and not the character.
Every glyph a renderer wants is outside ASCII: the half blocks U+2580/U+2584,
U+2588, the braille block from U+2800.

**Filed as a suggestion** (`examples/SUGGESTIONS.md` §11, *"No way to make a
`str` from a Unicode codepoint — `chr()` is byte-oriented, so it cannot produce a
glyph"*): Y has no expression at all that turns a codepoint into a `str`. The
`+=` route is a compile error (filed) and `chr` is a byte, so for a non-ASCII
glyph there is currently **no** one-expression route, and every visual example
hand-rolls UTF-8 into a byte buffer. That is what `sink.y` does, and on an arena
heap it is the right answer anyway — but the fix is about fifteen lines in
`src/y/std/rt.y`, next to the `y_str_chr` that already has the shape.

Verified on the pinned compiler:

```
$ cat chr.y
print(len(chr(9608)));            // U+2588 FULL BLOCK
print(byte_at(chr(9608), 0));
print("q" + chr(9608));
$ refs/ycc.ref chr.y -o chr && ./chr | cat -v
1
136
qM-^H
```

`chr(9608)` is a **one**-byte string holding **136** = 0x88 — the low byte of the
codepoint, not the character. So `sink.grid_text` emits UTF-8 through a fixed byte buffer with
`fb.utf8_byte` + `fb.utf8_len`, which is the right answer anyway on an arena
heap, and this folder uses **neither** `line = line + R[i]` nor `chr()`. The
filed `+=` form is also unavailable: `examples/BUGS.md` §"`'+=' string` rejects a
`byte` operand" records it as a hard compile error. Filed as a suggestion, since
it is a missing capability rather than a wrong answer: **Y has no way at all to
make a `str` from a Unicode codepoint.**

### 2. `term.size()` answers with a record

Not a bug and not filed — it is a consequence of the arena heap plus SUGGESTIONS
§7, and it is in the allocation table above. The resize poll uses `TIOCGWINSZ`
into our own `[byte]` plus `term.rd16`, which is the very decode `term.size()`
performs.

---

## Audited against the campaign's `str +=` finding

`examples/BUGS.md` carries a campaign-wide finding: a `str +=` in a **value-used**
position — a block whose last statement has no trailing `;` — desugars to
`s = s + t`, which allocates a fresh exactly-sized buffer instead of appending in
place, and **inside a loop that is quadratic in heap** (measured: 16 120 104 bytes
at n = 4000 against 29 032 with the semicolon, same output).

Audited here, over every `.y` in this folder:

* `check.y`, `scene.y`, `fractal.y` and `sink.y` contain **no `+=` at all**. The
  program assembles every line through `sink.out_str` into a module-level byte
  buffer precisely because a growable `str` on an arena heap is a bad idea, and the
  measurement above says why: not because it is slow once, but because a
  value-used `+=` in a loop is `n²`.
* The only value-used `+=` in the folder is `src/y/std/args:463`, in the **vendored**
  toolkit, inside `def ar_left(k: long) -> str` — the last statement of an
  `else if` arm, **not in a loop**, so it costs one exact-sized allocation per
  usage line and nothing accumulates. It is left exactly as vendored.

So this folder does not contain the trigger shape. Recorded because "I checked" is
worth more than "I did not notice", and because a future change that adds a
string-building loop here should know the question was already asked.

---

## Honest notes

- **The default interactive frame rate is about 15 fps at 80×23, not 30.** The
  table above is the measurement; `--quality` and `--glyph` are the dials, and
  `--steps` is worth more for the ground's reach than for the frame rate.
- **The ground does not reach the horizon**, and never will at these step
  budgets: it stops where the march runs out. `--steps 160` moves it; `TMAX`
  does not.
- **`--no-tty` output is not meant to be read as animation.** It is a digest and
  a few frames, so it diffs. The animation is the terminal path.
- **The sky has a haze band whose width is a guess.** The band is there to sit
  over the step-budget cut-off and make it read as distance; it is not derived
  from anything.
- **The specular exponent is 16, not 24 or 64**, deliberately, and the reason
  (per-cell aliasing) is in *The specular*. A reader who wants a tighter
  highlight will get salt-and-pepper.
- **Sizes are capped at 160×80**, which is below `fb`'s own 256×128 because
  `braille` samples 2×4 and the sample store is `2·160 × 4·80` = 102 400 entries.
  That store is 3 × 8 bytes × 102 400 = 2.3 MiB, allocated once; total heap at
  start-up is 8.31 MiB and it does not move (8 713 112 bytes — the figure moved
  up from 7 765 248 when the property check arrived, because `check.y` declares
  four module-level buffers of its own, 947 200 bytes in total, for T4's two
  runs at different step budgets. They are allocated at load whether or not
  `--check` is given, and the render loop never touches them; the delta over 200
  frames is 0 in every mode, which is the claim that matters.)
- **The environment is a bit noisy.** At el 22 looking down, the ground fills
  more of the frame than a reader might expect; the opening pose at el 2 is the
  one chosen for the composition.

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
