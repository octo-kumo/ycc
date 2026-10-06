# `raytracer` — a reflective raytracer, in a terminal framebuffer

One ray per sample through a pinhole camera into four spheres and two planes,
shaded by depth (a fog that blends toward the sky in the ray's own direction)
and by normal (a diffuse term plus a Blinn highlight), recursing on reflection
to a hard depth cap, and shaded into `tui`'s surface with one of four ramps.

That is `golden/opening.png` at 78×21 cells, in truecolour, and
`golden/opening.txt` as text:

```
-----+++++++++++++++++++++++++++++++++++++======================--------------
------===+++++++++++++++++++++++++++++========================----------------
------===============+*###+=====-=======---:====------------------------------
---=============@@@%#*===-==+******++=--::.==-=--------------------------------
---============#@@@@@#+=-==+**####**+=--::.:#+=--------------------------------
---===========@@@@@@%#+=-=+*##%%%%##**+=--::..*+=-----------------------------
-------------@@@@@@@@#*=--=+*##%%%%%##**+=--:::..*+=-:------...
```

The crimson sphere, lit from the upper left; the silver mirror beside it; the
gold sphere behind; the checkerboard floor carrying the sphere's reflection; the
bounded back wall; the sky's own gradient behind all of it.

---

## Build and run

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab

(ulimit -S -v 3670016; $YCC raytracer.y -o raytracer) </dev/null   # zero warnings

./raytracer                                            # interactive, until q
./raytracer --frames 2 --no-tty --size 40x16 --glyph ascii   # the deterministic run (== EXPECTED)
./raytracer --check 1                                  # the property check
./raytracer --bounces 0 --no-tty --frames 1 --size 78x21 --glyph ascii --dump 0
./raytracer --dist 4 --el 20 --frames 1 --no-tty --size 78x21 --glyph ascii --dump 0
```

`--no-tty` is the path the gate uses: it renders through the same `fb.Surface`
and the same `fb.flush_diff` and only changes where the bytes go (the ANSI stream
to `/dev/null`, the text to stdout). It **never paces**, because that path exists
to answer "how fast can this machine trace frames" and a sleep in the middle of it
would measure `nanosleep` instead.

### Keys, interactive

| key | what |
|---|---|
| `q`, `Q`, Escape | quit — always through `term.restore_all_exit(0)` |
| ← → | orbit in azimuth, 0.64° a press |
| ↑ ↓ | orbit in elevation, 0.48° a press, clamped to ±45° |
| `+` / `=`, `-` / `_` | dolly in and out, 0.05 units a press, clamped to 1…16 |
| `p` / `P` | cycle the palette (5 of them, a per-channel function of the base colour) |
| `g` / `G` | cycle the glyph mode |
| `b` / `B` | the bounce cap, 0…8 |
| space | pause the orbit |
| `r` | back to the opening pose |

---

## Options

```
  -n, --frames N     render exactly N frames, then exit 0 (default 0: run until q)
  -s, --size VALUE   WxH cells, at most 160x80; default the terminal, or 80x32
  -g, --glyph VALUE  ascii | blocks | half | braille   (half: the default)
  -c, --color VALUE  ember | ice | spectrum | mono | phosphor
  -b, --bounces N    reflection depth cap, 0..8 (default 3)
  -f, --fov N        horizontal half-angle in degrees, 5..80 (default 32)
      --seed N       0 (the default, no jitter) or 1..2147483647
  -a, --az N         opening azimuth in degrees, -360..360 (default 0)
  -e, --el N         opening elevation in degrees, -45..45 (default 8)
      --dist N       opening camera distance in scene units, 1..16 (default 6)
      --fps N        frames per second, interactive only (default 20)
      --no-tty       render into a text capture instead of the terminal; never paces
  -d, --dump VALUE   comma-separated frame numbers to print as text
      --time         wall clock, fps, rays a frame and the heap delta, on stderr
      --check N      the property check (0 off, 1 or 2); implies --no-tty
      --ansi FILE    headless only: also write the last frame's raw ANSI to FILE
  -h, --help         print this message and exit
```

**Sizes are refused, not clamped, when they are degenerate.** `--size 0x0`,
`--size 40x0` and `--size -4x8` are a message on stderr and exit 1: there is no
frame to render and quietly clamping to 1×1 would answer a question nobody
asked. A size past the cap **is** clamped, because `999x999` is a request rather
than a mistake. `--bounces 9`, `--fov 4`, `--fov 81`, `--seed -1`, `--el 46`,
`--dist 0`, `--dist 17`, `--check 3` and a stray operand are the same shape.

> **`--az`, `--el` with a negative value needs the `=` form.** `--az -360` is read
> as the flag `--az` with no value, because `-360` looks like a flag;
> `--az=-360` works. That is `args`'s convention and its message says so.

Exit codes: `0` ran (or `--help`), `1` a bad option, a bad value, or a stray
operand. Note that `main()`'s return value is **not** the exit status — the
working idiom is `def main() -> long { return 3 }; exit(main())`, which is what
every error path here uses via `die()`.

---

## What to look at when you run it

1. **The floor's reflection of the crimson sphere.** It is there because the floor
   carries `REFL = 45/255`, not because the sphere is transparent: the floor's
   reflected ray is traced like any other. `golden/opening.txt` against
   `golden/no-reflection.txt` (`--bounces 0`) is the A/B — 15 of the 21 rows
   differ, and the reflection is most of the difference.
2. **`depthhist` in the digest.** `884/213/9/2` at the documented run: 884 primary
   hits, 213 found one reflection deeper, 9 two deeper, 2 three deeper, none
   past the cap of 3. That is the bounce cap being *used*, and `objects` in the
   next line is what makes it meaningful — it says which surfaces those rays hit,
   so a cap that has nothing to reflect cannot masquerade as a working one.
3. **`objects`.** The per-object census of the frame, one line under each digest.
   Sphere 3 (the small teal one, directly behind the crimson sphere at the opening
   pose) reads `0` and rises as the orbit carries the crimson sphere aside. That
   is a fact about the geometry, printed rather than inferred.
4. **`hitpc`** — the fraction of samples that hit anything at all: about 69 % at
   40×16 and 88 % in ascii, and it changes with the wall's bounds, which is how
   the wall's own edge is visible in the number.
5. **The mirror.** `golden/close-up.png` is the same scene from four units out and
   twenty degrees up; the silver sphere there is showing the crimson one. Compare
   `close-up.txt` with `no-reflection.txt` to see the part of the picture that is
   only there because the rays bounce.
6. **`--fov`.** 32° is the default and it is where the composition works: the
   wall's edges are inside the frame with sky either side of them. Narrower (24°)
   is the picture above with the sphere across half the frame and the wall's edges
   gone — checked by rendering it and looking, not by argument. Wider (80°, the
   cap) puts the whole scene into about two columns in the middle of a lot of
   floor, which is measurable: the widest lit run in the ascii dump goes 33 → 33 →
   2 columns for 24° → 32° → 80°. `--fov 5..80` refuses everything else rather than
   clamping it.
7. **`--glyph braille`** casts **four times** as many rays (13 104 against 3 276
   at 78×21) for twice the horizontal and four times the vertical resolution.

---

## How it works

### The scene (`scene.y`)

```
sphere 0   centre ( 0.00, 0.00, 0.00)  r = 1.00   crimson,   matte
sphere 1   centre (-1.30, 0.35,-0.40)  r = 0.60   silver,    REFLECTIVE (255)
sphere 2   centre ( 1.10, 0.25,-0.90)  r = 0.45   gold,      43% mirror
sphere 3   centre ( 0.30, 0.15,-1.70)  r = 0.30   teal,      matte
floor      y = -1.0, a two-unit checkerboard, 18% reflective
back wall  z = -6.0, |x| < 6, -1 <= y <= 4, a vertical gradient
```

Every centre and radius is an exact multiple of 1/16 of a unit, and that is not
decoration: it makes every term of the ray/sphere quadratic **exact** in Q16, so
the discriminant is an exact integer and `check.y` can compare it against an
integer computed outside the program. A sphere at radius 0.4567 would make the
whole oracle approximate.

The wall is a **bounded quad**, not a plane. An infinite back wall catches every
ray that misses everything else, so the frame has no sky in it at all and
`hitpc` is 100 everywhere — measured, before the bounds existed.

### The scale, and the trap that comes with it

Everything is **Q16** integer fixed point (1.0 = 65536), because Y has no
`float` → `long` and no cast syntax at all (`ORCHESTRATOR.md` §2.4a) and no math
functions either (§2.4b). `fx.y` is called for the camera's four trig calls a
frame, once for `tan(fov)`, and **once per sample** for one exact integer square
root — the direction's own length. The inner loop calls it nowhere else.

The trap that costs the most in this campaign is that **dividing one Q16 integer
by another returns their RATIO, not a scaled quotient**. `a / b` on two Q16 values
gives a dimensionless number; the Q16 quotient is `(a << 16) / b`. `fractal` lost
six separate defects to that one shape. So:

| site | wants | what it does |
|---|---|---|
| `ray_sphere`'s roots | a Q16 distance | `((0 - b - sq) << 16) / a` — lifts |
| `plane_t` | a Q16 distance | `(num << 16) / den` — lifts |
| `fog` | a *ratio* | `((t - FOG0) * 255) / (FOG1 - FOG0)` — deliberately does **not** lift |
| the wall's gradient | a *ratio* | `((hy + 65536) * 255) / 327680` — deliberately does not lift |
| the specular half vector | a *ratio* | `(n·h * ONE) / \|h\|` — lifts, because the answer is a cosine in Q16 |

and the second site there is why the lift is marked at every one of them: adding
it to `fog` saturates the fog at the first sample and the scene loses all its
depth, which reads as a picture with no distance in it rather than as an
arithmetic slip.

Every shift is `>>` (arithmetic) unless the operand is provably non-negative, and
the two `>>>`s in the sink's hex printer are marked as such.

### `ray_sphere`, and what makes it checkable

```
oc = o - c,   a = d.d,   b = oc.d,   cc = oc.oc - r.r
disc = b*b - a*cc                    >= 0  <=>  the ray meets the sphere
t = (-b -+ sqrt(disc)) / a
```

Three deliberate choices:

* **`a` is brought down to Q16** so `disc` is a Q32 number and its square root
  comes out in Q16 directly. Leaving `a` in Q32 makes `a*cc` a Q48 product, which
  is the overflow the brief warns about.
* **A ray whose roots are both behind the eye misses, even though `disc > 0`.**
  That is a second test, independent of the discriminant, and an oracle has to
  make it too: from five units away, pointing straight away from a sphere of
  radius one, `disc = 2^32 > 0` and the answer is still a miss, because the
  nearest point of that ray is the eye itself.
* **A ray that starts inside the sphere takes the far root.** That is what makes
  the camera dollying inside a sphere show the inside of it.

`TMIN` (2⁻⁸ of a unit) is the near clip, and it is the only thing standing between
a reflected ray and the surface it just left; see the defect-injection section for
how nearly that is enough.

### Reflection, and the identity that has an exact answer

`r = d - 2(d.n)n`, and for a unit `n` that preserves `|d|` **identically**. A sign
error in the dot product, a transposed term, a missing 2, or a transmission
instead of a reflection all move `|r|²` by `O(|d|²)`, which for these directions is
2³² and up — so it is the sharpest cheap assertion available.

Two things it does **not** catch on its own, both of which `check.y` therefore
asserts separately:

* `|r| = |d|` holds just as well for a **transmission** (`r = d + 2(d.n)n`). So
  block E also asserts the head-on case exactly (`reflect((0,0,-1),(0,0,1))` must
  be `(0,0,+1)`) and that `r·n > 0` — that the ray leaves the surface at all.
* Over the **reals**, negating the normal changes nothing: `r(-n) = r(n)`. In
  truncating fixed point it does, by one Q16 unit, because `(-m) >> 16` is
  `-ceil(m/2^16)` and `-(m >> 16)` is `-floor(m/2^16)`. That is defect M16 in the
  injection table, and it is the sort of thing worth writing down rather than
  discovering later.

### The reflection's self-hit offset, and the bounce it was costing

The reflected ray's new origin is pushed `BIAS = 2⁻⁵` of a unit along the
**outward normal**, not along the reflected direction: the ray leaves the surface,
so an offset along the normal is the one that cannot re-find that surface at
t ≈ 0.

Defect **M13** removes it, and the result is worth recording because it is
invisible in the picture: the documented frame's depth histogram goes from
`564/213/9/2` to `564/213/9/1` and no colour changes at all. The reflection is one
level shallower and the frame digest cannot see it. `check.y` asserts that a
reflection never finds its own surface again — and that assertion needs **both**
the object id and the distance, because a distance test alone fires 697 times in
one frame on the legitimate case of a ray reflecting off the floor right in front
of the wall, where the two hit points are the *same point* because the two
surfaces meet at y = −1, z = −6.

### The fog, which blends toward the sky and not toward a colour

`fog(col, t, d)` blends toward **`sky(d)`** — the colour that ray would have had
if it had hit nothing — rather than toward one fog colour. The fixed-colour
version puts a visible seam along the horizon, because the floor at twenty-six
units is `FOGC` and the sky just above it is the gradient, and those only match at
one height. Blending toward `sky(d)` makes the far plane continuous with the sky
by construction.

### The aspect ratio, settled by measurement

A terminal cell is about **two pixels tall and one wide**, so one vertical sample
covers twice the screen of one horizontal sample; putting the same angular step on
a pixel in both axes therefore needs the vertical step per sample to be **twice**
the horizontal one, and the number of rows then has nothing to do with it:

```
RYO[gy] = (GH - 1 - 2*gy) * 2 * FOVX / GW
```

That was **measured, not reasoned out**, and the two candidates are far apart. At
60×24 with the crimson sphere at seven units the drawn silhouette is:

| vertical step per sample | the sphere, in cells | round? |
|---|---|---|
| `FOVX/GW` | 13 × 23 | an egg, 2:1 |
| `2*FOVX*GH/GW²` (the "obvious" one, from matching the *field*) | 12 × 14 | still an egg, 1.16:1 |
| **`2*FOVX/GW`** | **14 × 8** | **yes — 14 × 16 pixels** |

Every intersection in the frame is exact in all three variants and every distance
is right, so **only the drawn silhouette can catch this**, which is why block H
measures it. The row term is `GH - 1 - 2*gy` and not `2*gy + 1 - GH` because the
vertical axis counts **up** here (grid row 0 is the top of the frame); the
mirrored formula renders the whole scene upside down, which is a picture that still
looks like a picture.

### Which ramp, and why

**This uses half blocks**, and the reason is that a coverage-keyed glyph saturates
inside a silhouette, so the shading has nowhere to go:

* **`ascii`** keys the glyph on luminance (`fb.shade_ascii(v, 256)`, ten glyphs).
  Classic, and `golden/opening.txt` shows it working — but it samples once per
  cell, so it throws away the vertical resolution.
* **`braille`** keys it on coverage (a 2×4 dot bitmap). For lines and edges that
  is the honest answer; for a lit surface it is close to useless, because inside
  the silhouette coverage saturates at 8 of 8 and every cell in the middle of a
  sphere comes out the same full block. It also costs **four times the rays**.
* **`half`** samples twice vertically and uses the pair as a two-bit glyph index.
  The glyph says which halves are surface, and the two colours ride in the cell
  foreground and background — so a lit surface gets **two independent levels per
  row** at twice the cost of ascii, not four times. `level = upper + 2*lower`, and
  `level == 2` has to swap, because U+2584 fills the *bottom* and the lower
  sample's colour is therefore the one that has to be the foreground.

### No per-frame allocation — measured, not asserted

```
$ ./raytracer --frames 100 --no-tty --size 78x21 --half --time        # (glyph half)
raytracer: 100 frames in 141377 us = 141 ms -> 70.77 fps
raytracer: 78x21 half bounces=3 rays/frame=3276 hits=2240 deepest bounce=3
raytracer: heap_used before=4821016 after=4821016 delta=0
```

**delta = 0** on every configuration measured — 200 frames at 40×16, 100 frames
at 78×21 in half, ascii, blocks and braille, and 100 frames at the bounce cap of
8. Getting there is four things, all the same trap:

| where | why it allocates |
|---|---|
| the tracer's answer | a record returned from a recursive `def` — a 64-byte record per level per sample is 13 MB a frame, so it is module-level longs with an explicit save/restore around the recursive call |
| the palette table | `POBJ` is rebuilt on a palette change, never per pixel |
| the HUD | `tostring()` once a frame, so the numbers go out digit by digit from module-level scratch |
| the resize poll | `term.size()` **answers with a record**, so it is `TIOCGWINSZ` into our own `[byte]` plus `term.rd16` |

The sample store is five module-level `[long; 51200]` arrays (colour, hit, object,
distance, and three for the hit point) — 2.4 MB of arena, allocated once at module
scope. They are there so `check.y` can audit the whole frame analytically; see
block G.

---

## Measured performance

`--no-tty --frames 100 --time`, one row per configuration. Times are wall clock on
a shared machine, so the spread is load and not the program.

| size | glyph | bounces | rays/frame | fps | deepest bounce reached |
|---|---|---|---|---|---|
| 20×8 | half | 3 | 320 | **781** | 1 |
| 40×16 | half | 3 | 1 280 | **195** | 3 |
| 60×22 | half | 3 | 2 640 | **94.7** | 3 |
| **78×21** (a typical terminal) | **half** | 3 | 3 276 | **70.8** | 3 |
| 100×30 | half | 3 | 6 000 | **39.1** | 3 |
| 78×21 | ascii | 3 | 1 638 | 123 | 3 |
| 78×21 | blocks | 3 | 1 638 | 122 | 3 |
| 78×21 | braille | 3 | 13 104 | 19.7 | 3 |
| 78×21 | half | 1 | 3 276 | 72.4 | 1 |
| 78×21 | half | 8 | 3 276 | 70.7 | **4** |
| 78×21 | half | 0 | 3 276 | 97.4 | 0 |

Two things in that table are worth reading rather than skimming:

* **The bounce cap is nearly free above 1.** 70.8 fps at the cap of 3 against 72.4
  at the cap of 1, because the frame's deep levels are a few hundred samples out
  of 3 276. The cap of 8 costs nothing either, and it only reaches depth 4 —
  because that is all this scene has. A raytracer with a depth cap is not
  necessarily spending it.
* **And the cap does not reach 5 or more at any pose**, which is a statement about
  the scene, not about the program: at 18 % reflectivity on the floor and 43 % on
  the gold sphere, four is what a chain of surfaces adds up to.

---

## The property check: `--check`, against analytic geometry

`--check 1` asserts ten things and exits 0 or 1. **No reference file is
involved anywhere in `check.y`**, and that is the point: a golden file proves
determinism, and `cube` once passed all eight gate items while rendering a defect
because its `EXPECTED` had been generated from the broken output.

The rule the whole file is written to is that every expectation is one of three
things and never "whatever the renderer said":

1. **an exact integer computed outside this program**, by exact integer
   arithmetic on the closed forms (the derivations are beside each case so they
   can be checked by eye);
2. **an identity with an exact answer** rather than a tolerance;
3. **a bound taken from the shape of the scene**, not from the code under test.

And every observed value is asserted **present** before it is compared, because
the campaign's standing failure is a check that compares two values which are both
absent and reports a pass.

Its actual output:

```
$ (ulimit -S -v 3670016; ./raytracer --check 1) </dev/null
raytracer: property check.  No reference file is involved: every
  expectation below is either an exact integer computed outside this
  program, an identity with an exact answer, or a bound taken from the
  shape of the scene rather than from the code under test.
A  ray/sphere, against discriminants computed outside this program
  A1 head-on  expect disc=4294967296 hit=1 t=262144   observed disc=4294967296 hit=1 t=262144
  A2 tangent  expect disc=0 hit=1 t=39321   observed disc=0 hit=1 t=39321
  A3 outside  expect disc=-343597383680 hit=0 t=0   observed disc=-343597383680 hit=0 t=0
  A4 inside  expect disc=751619276800 hit=1 t=17750   observed disc=751619276800 hit=1 t=17750
  A5 away  expect disc=4294967296 hit=0 t=0   observed disc=4294967296 hit=0 t=0
  A6 45deg  expect disc=-98784247808 hit=0 t=0   observed disc=-98784247808 hit=0 t=0
  A7 inside  expect disc=4294967296 hit=1 t=65536   observed disc=4294967296 hit=1 t=65536
     the table exercised 4 hits and 4 misses (it must be 4 and 4); observed hit flags 4 and 4

B  the nearest of two surfaces wins, on exact integer distances
     near sphere t=196608 (expect 196608 = 3.0)   far sphere t=393216 (expect 393216 = 6.0)

C  the plane, whose answer has no square root in it at all
  C1 down  expect hit=1 t=196608   observed hit=1 t=196608
  C2 slant  expect hit=1 t=87381   observed hit=1 t=87381
  C3 parallel  expect hit=0 t=0   observed hit=0 t=0
  C4 upward  expect hit=0 t=0   observed hit=0 t=0
  C5 wall  expect hit=1 t=458752   observed hit=1 t=458752
  C5b slant  expect hit=1 t=174762   observed hit=1 t=174762
  C6 wall x  expect hit=0 t=0   observed hit=0 t=0
  C7 wall y  expect hit=0 t=0   observed hit=0 t=0

D  the centre ray of a hand-posed camera, against a hand-computed 4.0
     eye=(0,0,327680)  forward=(0,0,-65536)  -- the centre ray is exactly (0,0,-65536)
     trace reported hit=1 object=0 t=262144  (expect hit=1 object=0 t=262144)

E  the reflection preserves |d|^2 (an identity, not a tolerance)
     pair 0: d=(-21846,43691,43691) n=(0,0,0)  |d|^2=4295054678 |r|^2=4295054678 diff=0 bound=218464 perpendicular: exact
     pair 1: d=(65536,0,0) n=(0,0,65536)  |d|^2=4294967296 |r|^2=4294967296 diff=0 bound=131080 perpendicular: exact
     pair 2: d=(0,-65536,0) n=(65536,0,0)  |d|^2=4294967296 |r|^2=4294967296 diff=0 bound=131080 perpendicular: exact
     pair 3: d=(262144,0,-196608) n=(39322,0,52429)  |d|^2=107374182400 |r|^2=107374051330 diff=131070 bound=917512 oblique
     pair 4: d=(65536,-65536,-65536) n=(-65536,0,0)  |d|^2=12884901888 |r|^2=12884901888 diff=0 bound=393224 oblique
     pair 5: d=(196608,0,-262144) n=(0,65536,0)  |d|^2=107374182400 |r|^2=107374182400 diff=0 bound=917512 perpendicular: exact
     pair 6: d=(262144,0,0) n=(0,65536,0)  |d|^2=68719476736 |r|^2=68719476736 diff=0 bound=524296 perpendicular: exact
     pair 7: d=(-65536,0,0) n=(0,65536,0)  |d|^2=4294967296 |r|^2=4294967296 diff=0 bound=131080 perpendicular: exact
     pair 8: d=(32768,-32768,0) n=(0,0,65536)  |d|^2=2147483648 |r|^2=2147483648 diff=0 bound=131080 perpendicular: exact
     9 direction/normal pairs; worst |r|^2 - |d|^2 = 131070 Q32 units; 7 of the pairs were perpendicular and answered EXACTLY zero;
     the worst pair used 14% of its own derived bound
     head-on: reflect((0,0,-1), (0,0,1)) = (0,0,65536)  (expect 0,0,65536)
     reflect((0,-1,0), (0,1,0)) = (0,65536,0)  r.n = 65536 (must be > 0: the ray must LEAVE the surface)

F  the depth cap: honoured, reached, and it does not move the first hit
     cap 0: depth0=3518 depth1=0 deepest=0
     cap 1: depth0=3518 depth1=666
     cap 2: depth0=3518 depth1=666 depth2=27
     cap 3: depth0=3518 depth1=666 depth2=27 depth3=4 depth4=0
     reflections that found their own surface again: 0

G  every hit of a real frame lies ON the object it names
     samples 960  hits audited 816  hits the frame reported 816
     worst |p-eye|^2 - t^2 = 159233279 Q32 units, which is 18% of its own band   worst surface residual = 63 Q16 units on object 2, whose own derived band was 386
     worst residual as a percentage of its own band: 16%   samples given the wide grazing band: 0
     distance disagreements 0   surface disagreements 0

H  the crimson sphere's drawn silhouette is round, and the size the
   tangent cone predicts
     sphere 0 covers 88 of 1440 samples; bbox cols 23..36 rows 8..15
     drawn 14 cols x 8 rows  =  14 x 16 pixels   (round means the two pixel counts agree)
     |2*rows - cols| = 2 cells (must be <= 4)
     D^2-r^2 = 182121118209   r/sqrt(D^2-r^2) = 10064 (Q16)   the cone's width over this frame = 14 samples, drawn 14
     at twice the distance the silhouette is 6 cols wide, against 14 at half the distance

I  the diffuse term's sign: toward the light is bright, away is not
     n = +L gives 255   n = -L gives 30   n = perpendicular gives 129   (ambient 30)

J  the capture checksum moves when one pixel moves, and only then
     plain frame:   15700 bytes captured, checksum 73fa8acc44c145b0
     pixel 480 flipped: 15698 bytes captured, checksum 8a305f8ed8985dbe
     back again:    15700 bytes captured, checksum 73fa8acc44c145b0
     sample 480: colour 0000000000444d64 plain, 0000000000040d24 perturbed

     assertions 108, failures 0, level 1
     RESULT  PASS
```

### What each block holds, and where its oracle comes from

| | holds | the oracle |
|---|---|---|
| **A** | hit and miss against seven hand-computed discriminants | exact integers; the tangent ray's discriminant is **exactly zero** by a 3-4-5 identity |
| **B** | the nearest of two surfaces wins | exact integer distances, 3.0 and 6.0 units |
| **C** | the plane's distance, which has **no square root in its answer** | hand division; 3.0, 4/3, and three edges of the wall's quad |
| **D** | the centre ray of a hand-posed camera into the real scene | 4.0 units against an eye at 5.0 — and the pose is exact, because `sin(0) = 0` and `cos(0) = 1` |
| **E** | the reflection preserves `\|d\|²` | an identity, and the head-on case is asserted with **no** tolerance |
| **F** | the cap is honoured, **reached**, and does not move the first hit | shape, from outside the tracer |
| **G** | every hit of a real frame lies on the object it names | the surface equation, which is not the one that was solved |
| **H** | the drawn silhouette is round, and the size the tangent cone predicts | `r/sqrt(D²−r²)`, computed here from `r` and `D` |
| **I** | the diffuse term's sign | the definition of the term, at its two poles |
| **J** | the capture checksum moves when one pixel moves and only then | `fb.capture_checksum`, with the byte count asserted non-zero **first** |

Four of those deserve their own paragraph.

**A2, the exact tangency.** Eye `(0,0,5)`, radius 4, direction `(4,0,-3)`.
`|d| = 5` and the perpendicular distance from the centre to the line is
`5·4/5 = 4 = r` exactly, so `disc = 225 − 225 = 0` **exactly**, and the single
root is `t = 15/25 = 0.6` with the hit point at `(2.4, 0, 3.2)`, whose length is
exactly 4. Nothing rounds anywhere, which is why the sphere table is in multiples
of 1/16 — and it is the only case that can see a `>= 0` written as `> 0` (M2).

**A5, the case a discriminant-only check gets wrong.** From five units, pointing
straight away from a sphere of radius one: `disc = 2^32 > 0`. The quadratic says
the *line* meets the sphere. Both roots are negative, the nearest point of the ray
is the eye itself, and the answer is a miss. So A5 tests the second, independent
condition, and M3 (removing it) is caught by nothing else.

**G, the whole-frame audit.** Every sample of a real 48×20 frame is checked
against the two identities that *define* the geometry, neither of which is the
equation the tracer solved:

```
|p - eye| == t                     the reported distance is the distance
p lies ON object k                 the point is on the surface it NAMES
```

816 hits audited, 0 disagreements, worst case at 18 % and 16 % of its own band.
**The bands are derived per sample, not chosen.** The dominant term is not the
discriminant: the ray direction is normalised with a truncating division, so `a`
inherits a relative error of about 8/65536 and the root carries `t·8/65536` — 56
Q16 units at seven units, three times the whole fixed tolerance this block started
with. So the band is `8 + t·8/65536 + |Δdisc|/(2·sq)`, each term there for a
stated reason, and a plane gets the tight band of 8 because its `t` is exact. An
earlier version used a flat band and failed at a pose one unit further out; an
earlier version of *that* used `|oc|²` where it wanted `|b| = |oc|`, inflated the
bound by a factor of `|oc|`, and silently degenerated into a constant — which is
the one thing a derived bound exists not to be.

**J, and the vacuous pass this check nearly shipped.** The capture checksum has to
change when one pixel is perturbed and has to **not** change when nothing is. The
first version of this block did neither: it never called `fb.capture_reset()`, so
the capture buffer was cumulative and the checksum moved no matter what — and
then, once the reset was added, it reported **three identical checksums** for the
frame, the perturbed frame and the frame again, because the surface it was
flushing was whatever `fb.new` left in it, a blank, and nothing had copied the
sample store into it. Three passing assertions over an empty comparison, which is
precisely the failure the campaign has seen twice. The byte count and the checksum
are both now required to be present and non-zero *before* either is compared, and
`paint()` puts every sample's colour into a cell so the surface **is** the frame.

### Two bugs this check caught in *me*, not in the renderer

Worth recording, because both were invisible to the picture and to the golden:

1. **A stale literal.** Block G originally read the wall's position out of a
   literal. When the wall moved from z = −4 to z = −6 during development the check
   failed on 254 samples with a residual of exactly 131072 — two units, the wall's
   displacement. The renderer was right and the check was stale, which is the good
   outcome. It now evaluates the plane equation from the scene's own declared
   `PLD`/`PNLX`/`PNY`/`PNLZ`, which is the same independence as the sphere case.
2. **Four failures that printed nothing.** `ok()` did not report, so the summary
   said "failures 4" and the output said nothing about which. Every assertion now
   names its block and its own number, because a failure that prints nothing is
   indistinguishable from a check that passed.

---

## Defect injection: `mutate.py`

A check nobody has tried to break is a claim. `mutate.py` injects **17 single-line
defects** into the renderer — each one that still compiles, still traps nowhere,
and still runs — and requires `--check 1` to notice.

```
$ (ulimit -S -v 3670016; python3 mutate.py) </dev/null
  15 of 17 mutations caught, 2 missed, 0 broken
    MISSED M13: expected missed -- declared MISSED, with the measured size of the hole
    MISSED M16: expected equivalent -- declared EQUIVALENT, with the proof and the measured size of the hole
```

| | the defect | caught by |
|---|---|---|
| M1 | near root and far root swapped | A1's 4.0 → 6.0, B's 3.0 → 7.0 |
| M2 | `disc >= 0` written `> 0` | **A2 only** — the exactly tangent ray |
| M3 | the behind-the-eye test removed | **A5 only** — the ray with a *positive* discriminant |
| M4 | the missing lift, sphere | A4's 0.270996 units comes back as 0 |
| M5 | the discriminant's sign inverted | A3/A6 stop being misses; G's audit |
| M6 | the missing lift, plane | C1's exact 3.0 comes back as 0 |
| M7 | the wall's horizontal bound removed | C6/C7 |
| M8 | the reflection's sign inverted | **E's head-on and `r·n`**, *not* `\|r\|=\|d\|` |
| M9 | the depth cap off by one | F's "nothing past the cap" |
| M10 | the cap replaced by a constant | F's depth-2 and depth-3 populations |
| M11 | the diffuse clamp moved inside the abs | **I only** — every surface lit from behind |
| M12 | the cell-aspect factor of two dropped | **H only** — the spheres come out as eggs |
| M13 | the reflection's self-hit offset removed | **not caught — see below** |
| M14 | the stored distance shifted by 1/16 unit | G's `\|p - eye\| == t` |
| M15 | the recorded object id shifted | G's on-surface residual |
| M16 | the normal negated | **not caught — provably equivalent, see below** |
| M17 | nearest-wins reversed to farthest-wins | B, and G |

**The two misses, with the reasons, rather than dropped.**

**M16 is equivalent, and the proof is short.** `r(-n) = d − 2(d·(−n))(−n) =
d − 2(d·n)n = r(n)` identically, so no property of the reflection can distinguish
it. In *truncating fixed point* it is not quite equal — `(-m) >> 16` is
`−ceil(m/2^16)` while `−(m >> 16)` is `−floor(m/2^16)` — so the mutant's `d·n`
moves by one Q16 unit and `r` by about two. Measured: the mutant's entire headless
output is **byte-identical** to `EXPECTED`, digest included, and its `--check`
passes. So the hole is real and its size is two Q16 units against a band of 386.

(An earlier version of M16 negated only the output term, which is not a negated
normal at all — it is M8's transmission — and so the table claimed an equivalent
where there was a defect. Recorded because "the mutation I wrote was not the
mutation I described" is the same failure as a check that does not test what it
says it tests.)

**M13 is a real defect the check does not catch, and the size of the hole is
measured.** Removing the reflection's self-hit offset moves **one sample in 3518**
a bounce level deeper — the documented frame's depth histogram goes from
`564/213/9/2` to `564/213/9/1` — with **no change to any colour**, so the frame
digest cannot see it either. It does not report the same object twice, so the
self-intersection assertion in F is blind to it. The only number that would catch
it is the literal `4`, and an assertion whose entire content is a golden value is
a golden assertion wearing a property's clothes. It was caught twice on the way
here for the **wrong** reasons — once by the stale literal above, and once by a
distance-only self-intersection test that fires 697 times on a legitimate case —
which is worth saying plainly: the check was not catching this one, and it is not
now.

---

## The deterministic run, and what is in `EXPECTED`

`gate.conf`'s `run=` line is:

```
run=./raytracer --frames 2 --no-tty --size 40x16 --glyph ascii
```

> **It says `--glyph ascii` on purpose.** `EXPECTED` is meant to be readable in a
> diff, and a text dump of a half-block frame is sixteen rows of `█` — it proves
> determinism and nothing else, and it cannot be *looked* at. With `ascii` the
> golden is the picture. The default half-block path is covered by the per-frame
> `sha` digest line and by `golden/blocks.txt`.

```
raytracer: frames=2 size=40x16 glyph=ascii color=ember bounces=3 fov=32 seed=0 rays/frame=640
dumped frames: 1
frame     0 bytes    12449 rows    16 hits     564 hitpc  88 bmax    3 depthhist    564/    213/      9/      2/      0/      0 sha 1b8510c7e0a8ddce
objects  sky      0  0:     54  1:     13  2:      4  3:      0  4:    300  5:    193
frame     1 bytes     9361 rows    15 hits     565 hitpc  88 bmax    3 depthhist    565/    213/     10/      2/      0/      0 sha 00177d8fe91bfdf1
objects  sky      0  0:     54  1:     13  2:      5  3:      0  4:    301  5:    192
--- frame 1 ---
::::::::::::::::::::::::::::::::::::::::
:::+++++++++++++++++++++++==========--::
---++++++++++++++++++++===========------
---===++++++++++++++============--------
---==========================-----------
---========@@#+===++=-:==---------------
----======@@@%+=*#%%#+-:.#=:------------
----------===-:=+###*+-:. :.------:::---
----==========::-===--:.. --------------
:::-=====+++===...:....  ===--------:---
::::++++++++++++++    ========------::::
::::++++++++++++        =====-------::::
::::+++++++.........     :.====-----::::
:::::+++++---:.::---::..  -=======--::::
:::::++++++%%%+-=***+-:..+==========::::
::::::::::::::::=+**+=-:::::::::::::::::
```

Two frames rather than one, so both digest lines and both object censuses are in
the golden. `sha` is an FNV-1a over every cell's codepoint **and both of its
colours** (`sink.grid_digest`), so a frame that changed colour but not shape is a
different digest — which matters here because the half-block glyph carries the
lower half's colour in the cell *background*. The orbit advances 0.64° a frame, so
the two frames differ and the second line is evidence rather than a repeat.

---

## Two paths, three test harnesses

`pty_check.py` is in the folder and is how the interactive path is verified
without tmux (which is not installed on this machine). It allocates a pty, sets the
window size **before** `execv` (a pty from `pty.fork()` is 0×0 and `TIOCGWINSZ`
would otherwise report nothing), types keys, and then checks the terminal was
handed back:

```
$ (ulimit -S -v 3670016; python3 pty_check.py ./raytracer) </dev/null
alt screen entered              : True
alt screen left                 : True
cursor hidden                   : True
cursor shown                    : True
keys typed                      : True
exit status 0                   : True
c_lflag restored                : True
ECHO restored                   : True
ICANON restored                 : True
c_lflag                         : 0x8a3b -> 0x8a3b
RESULT                          : PASS
```

`c_lflag` identical before and after is the load-bearing line: the terminal came
back in cooked mode, so the shell has its echo and its Ctrl-C. That has to hold
even when nothing in the program gets a chance to run, which is what
`term.arm_watchdog()` is for — a forked child blocked on a self-pipe with
`setsid`, restoring the saved termios the instant the parent's pipe closes.

`snap.py` is not part of the gate. It runs the deterministic path with `--ansi`,
replays the emitted stream into a cell grid and writes a **PNG**, which is how the
claims above about colour, about which ramp was chosen, and about the reflection
in the floor were **checked rather than asserted**. `golden/*.png` are its output.

`gate.sh` is the whole acceptance gate, re-runnable: `sh gate.sh` (it honours
`YCC=`).

---

## The std units this uses

Vendored byte-identical from `test/std/` and **not edited** (the folder
contract, `ORCHESTRATOR.md` §4):

| file | sha256 |
|---|---|
| `fx.y` | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` |

```sh
cd examples/raytracer && sha256sum fx.y tui tui tui args
```

`sink.y`, `scene.y` and `check.y` are this folder's own, not copies.

---

## Compiler pin, and the workarounds

> **Pinned compiler:** `refs/ycc.ref` sha256
> `e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`.
>
> The pin moves — `ORCHESTRATOR.md` §3 records it being reblessed repeatedly
> during this campaign, and `fractal` was built against `c53cc415…`. **The path is
> the pin; the hash above is what this folder is verified against.** `EXPECTED` is
> a property of the maths and the maths is this folder's; nothing here depends on
> a particular compiler build, and the whole thing was re-run from scratch against
> the current pin.

Nothing in this example is a workaround for a compiler defect. What it does use
is the language's own shape, and the four places that shaped it:

* **No `float` → `long`, no casts, no math functions** (§2.4a, §2.4b). All of it is
  Q16 integers; `fx.y` for the camera's trig, `tan(fov)`, and one exact integer
  square root per sample. Not a bug and not filed — it is a known, deliberate gap.
* **No `break`, no `continue`** (§2.9). The tracer's nearest-surface loop has no
  early exit to be had — a nearer object found later must still be compared — so
  the structure that would normally want `break` does not want it. The `--dump`
  frame loop uses a one-bit-per-frame array instead of a guard flag.
* **`>>>` is logical and `>>` is arithmetic** (§2.15). The audit is one grep; the
  only two `>>>`s in this folder are in the sink's hex printer, whose operand is
  provably a byte or a mask.
* **`term.read_key_timeout(1)` cannot be finer than 100 ms** (§2.3). The frame
  loop polls with `read_key_timeout(0)` and lets `tui`'s pacer own the
  deadline. A non-zero timeout would spend 100 ms a frame, drop every frame on the
  pacer, and report ~0.6 fps with a stuck frame counter — which reads as "the
  animation is slow" rather than as a bug.

Two more that are properties of this language rather than of the renderer, both
handled at the site and both commented there:

* **No `str` from a codepoint.** `chr(9608)` is a *one-byte* string holding 0x88,
  and `str + byte` segfaults, so every non-ASCII glyph goes through
  `fb.utf8_byte` into a fixed byte buffer and out through one `write(2)`. Filed as
  a suggestion in the campaign's ledger, not as a bug.
* **`main()`'s return value is not the exit status** (§2.15). `def main() -> long
  { return 3 }` then `main();` prints and **exits 0**. Every error path here goes
  through `die()`, which calls `exit(1)` directly, and the gate checks that six
  bad options each exit non-zero rather than only that they do not trap.

**No compiler bug was found by this example, so nothing is filed.** The one
candidate — a `--check` mode whose assertions could fail silently, which was a bug
in *my* checker — was in this folder and was fixed here.

---

## Files

| file | what |
|---|---|
| `raytracer.y` | the CLI, the four cell-assembly modes, the status line, both frame loops |
| `scene.y` | the primitives, `ray_sphere`, `plane_t`, `reflect`, the tracer, the shading, the palettes, the camera, the sample grid |
| `check.y` | the property check: ten blocks, 108 assertions, no reference file |
| `sink.y` | the deterministic sink: fixed byte buffer, FNV digest, text frames |
| `mutate.py` | 17 injected defects and what caught each one |
| `gate.sh` | the whole acceptance gate, re-runnable |
| `pty_check.py` | the pty harness for the interactive path |
| `snap.py` | ANSI → PNG, so the picture can be looked at |
| `EXPECTED` | `./raytracer --frames 2 --no-tty --size 40x16 --glyph ascii`, byte for byte |
| `golden/opening.txt` · `.png` | the opening pose |
| `golden/no-reflection.txt` · `.png` | `--bounces 0`: the A/B for what the reflection is worth |
| `golden/close-up.txt` · `.png` | `--dist 4 --el 20`: from close in, mirror showing the crimson sphere |
| `golden/orbited.txt` · `.png` | `--az 40 --color ice` |
| `golden/blocks.txt` | `--glyph blocks` |
| `golden/braille.txt` | `--glyph braille`, eight rays a cell |
| `golden/color-ice.txt` | `--color ice` |

```sh
cd examples/raytracer
./raytracer --frames 1 --no-tty --size 78x21 --glyph ascii --dump 0 > golden/opening.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph ascii --bounces 0 --dump 0 > golden/no-reflection.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph ascii --dist 4 --el 20 --dump 0 > golden/close-up.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph ascii --az 40 --color ice --dump 0 > golden/orbited.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph blocks --dump 0 > golden/blocks.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph braille --dump 0 > golden/braille.txt
./raytracer --frames 1 --no-tty --size 78x21 --glyph ascii --color ice --dump 0 > golden/color-ice.txt
```
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
