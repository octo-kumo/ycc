# `mandelbrot` — a threaded Mandelbrot explorer, in Q30 fixed point

The Mandelbrot set, sampled on a grid of terminal cells, coloured by
**continuous** (smooth) escape time, drawn across a pool of worker threads
that share nothing but a work queue. Pan and zoom it in a terminal, or render
N frames to a byte-exact text capture and diff it.

```
%@@@@@     ....:::::----===++**##############*******+++++=====----:++===
@@@@@    ....::::----===+####%%%%%%%%%%%%%%%%%%######****++++====---:::+
@@@     ....:::----===+%%%%@@@@@            @@@@@%%%%%###***++++===----:
@@    ....::::---===%@@@@   ......::::::::......   @@@@%%%##***+++===---
@    ....:::---===@@   ..:::----============----:::..   @@%%%##***++===-
    ...::::--===+  ..::--==+--==++**#%%@@      @+==--::..  @@%%##***++==
   ...:::---=== ..:--==::--=++**#%@ .:-=+# -#+.%+-:.@==--:..  @%%##***++
  ...:::---==+.::-=+::--=++*#%%@ .-=-=*%:=..=- %= *==: @+=-::.  @%%##**+
 ...:::---==+:--=::--=++*##%@ .-=-=*#@.=* @@==@   - #+-: @#=--:.  @%%##*
...:::---==+:-=:--=++*##%@ .:-=+*#@ :=@:*#%@: #=% .*-:@*=.@%*=-::. @%%##
...:::--==+-=--=++*##%@  :-=*#%@.:=.*%.=@      :+==%=: + +: %*+=-:. @@%#
..:::--===-==++*##%@  .:-=@ :-+*@-.#: %--*-@#  +.#.@@%%.*-#: %*+=-:. @@%
.:::---==+++*#%@@ .::-=.-+=+*% =*.:#+               @ *+:%:=: %*++=-:. @@
.:::--==+=#%@ .:-== : =*++--=@.=@=:=*                 -*#==@=.@#*==-:. @
```

That is `golden/frame-000-72x36.txt` — the default view, span 3.6, `--maxit 240`
— written to disk as plain text so you can see the set without running
anything. Note that it is **mirror-exact about the real axis**: row *r* and row
*rows-1-r* are identical, because the grid is sampled symmetrically about the
origin and every pixel is a pure function of its coordinate (see
"the half-pixel that is not cosmetic" below).

---

## Build and run

The folder is self-contained. Everything it needs is in it.

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631

(ulimit -S -v 3670016; $YCC mandelbrot.y -o mandelbrot) </dev/null   # zero warnings

./mandelbrot                                # interactive explorer, until q
./mandelbrot --frames 3 --no-tty            # the deterministic run (== EXPECTED)
./mandelbrot --at=seahorse --maxit=400      # a named view
./mandelbrot --palette=ember --shade=lum    # another palette, glyphs by luminance
./mandelbrot --size=100x50 --maxit=900 --time --dump=0   # big, timed, one frame
```

`--help` lists every flag. The ones worth knowing:

| flag | meaning |
|---|---|
| `--frames N` | render exactly N frames, then exit 0. **Deterministic mode.** Each frame halves the span, so the frames differ and a digest per frame is worth something. |
| `--size WxH` | grid in cells, clamped to `1x1..256x128`. Default: the terminal minus the status row, or `72x36` with `--no-tty`. |
| `--maxit N` | iteration cap, clamped `0..1000000`. `0` is legal: every pixel is then inside the set, which is a blank frame and `inside = cells`. |
| `--threads N` | workers, clamped `1..64`. `1` renders **inline, with no threads at all**. Default: this machine's CPUs via `sched_getaffinity`, capped at 8. |
| `--at NAME` | a named view: `full`, `seahorse`, `elephant`, `double`, `spiral`, `needles`, `random`. |
| `--center X,Y` | the centre in decimal, e.g. `--center=-0.743643887,0.131825904`. |
| `--zoom N` | N halvings of the span, `0..48`. |
| `--seed N` | seed for `--palette=random` and `--at=random`. Same seed, same picture. |
| `--palette` | `blue`, `ember`, `ice`, `mono`, `grass`, `random`. |
| `--shade` | `iter` (glyph follows the colour band) or `lum` (follows the palette's luminance). |
| `--dump LIST` | frames to print as text. Default: every frame while `--frames <= 8`, else the last. |
| `--chars` | build the dumped frames through a `str` instead of the byte buffer — a cross-check, see below. |
| `--time` | wall clock, ms a frame and the heap delta, on **stderr**. |

**Keys, interactive:** arrows or `hjkl` pan, `+`/`-` zoom, `0`..`6` jump to a
named view, `[` and `]` change `--maxit`, `r` returns to the starting view, `q`
or Escape quits. The window is re-read every 16 frames and follows a resize;
Y has no `SIGWINCH` to tell us sooner. An **idle explorer costs nothing** — it
redraws only when the view, the grid or `--maxit` actually changes, and the
workers are parked on a semaphore the rest of the time.

---

## What to look at

**`./mandelbrot --frames 3 --no-tty`** prints the run `EXPECTED` holds. The
interesting parts of the output are the per-frame lines:

```
frame    0 span 3.600000 escaped   2288 inside    304 mean-it-x10    317 ansi    4326 sha 870bef69c882caab
```

- `span` — the real width of the window in complex-plane units, to six
  decimals, halved each frame.
- `escaped` / `inside` — how many of the 2592 cells are outside the set. 304
  inside is the right answer: the set's area is about 1.5 and the window is
  3.6 × 3.6.
- `mean-it-x10` — mean iterations per cell, times ten so it is an integer.
- `ansi` — bytes the terminal path emitted for this frame, sent to `/dev/null`.
  It is there so the `ansi` column is *evidence the ANSI path ran*, not a
  claim that it would.
- `sha` — FNV-1a over every cell's packed shade, both the band and the
  iteration count. This is the number to diff.

**Two sinks, one picture.** `render.CELLS` holds the frame; the terminal path
puts it into a framebuffer and the text path reads the same cells. `--chars`
additionally re-renders every dumped frame through a completely independent
sink — a `str` built one `chr()` at a time — and the bytes have to come out
identical. They do, which is a self-test and not decoration:

```
$ diff <(./mandelbrot --frames 3 --no-tty) <(./mandelbrot --frames 3 --no-tty --chars) && echo same
same
```

**Thread count is not in the picture.** This is the property worth checking
first, because it is what makes the deterministic run machine-independent:

```
$ for t in 0 1 2 4 8 16 32 64; do ./mandelbrot --frames 200 --no-tty --threads $t --dump=0,199 | sha256sum; done | sort -u
824ed20ea71d812c51ed217e  -
```

One line, for every count. Repeated: 100 runs across threads 4/8/16/64 at 40
frames, and 40 runs at `--threads 8` with six copies competing for the machine,
all byte-identical. So the gate's `EXPECTED` does not have to name a core
count, and `gate.conf`'s `run=` line does not need `--threads` in it.

---

## The overflow strategy, in full

The brief asked for one, and the answer has two halves. Both are necessary.

**The trap.** The textbook iteration squares the coordinate, and in Q30 that is
a Q60 number: `x` is `2^30` when `x_real` is 1, so the product needs 62 bits
and the sum of the two squares needs 63. Worse, the moment a point escapes,
`|x|` can be up to `|z|² + |c| ≈ 6.5` and `|y|` up to 8.6, and squaring *that*
needs 66 bits and wraps to a small number. A wrapped square is not a slightly
wrong picture; it makes the orbit look bounded again, so the pixel is reported
**inside the set**.

**Half one: every product goes through `fx.mul`, which cannot overflow.**
`fx.mul`'s fast lane only forms `x*y` when one operand is under `2^32` and the
other under `2^31`; anything larger falls through to `mul_wide()`, which builds
the full 124-bit product in 16-bit limbs and keeps the bits. So
`fx.mul(7e9, 7e9)` — a product that does not fit in 64 bits — answers
correctly. This is why there is **no bare multiplication of two coordinates
anywhere in `mandel.y`**. Verified: `fx.mul` is exact on perfect squares across
four ranges and 1.2e-9 relative elsewhere (fx.y's own header).

**Half two: the iterate is never unbounded, so the products are small anyway.**
The loop tests the escape condition at the **top** of each iteration, on the
`z` it is about to square. So the only `z` ever squared satisfies `|z|² < 4`,
i.e. each component is under 2 — every product is then below `2^62` and even a
naive `x*x` would have been fine. The escape test itself is evaluated on a `z`
that has *not* yet been through the test, so it is the one place a big product
appears, and it is exactly the place `fx.mul` is needed.

```
while (n < maxit && done == 0) {
    let a = fx.mul(zr, zr);          // exact for any magnitude
    let b = fx.mul(zi, zi);
    m2 = a + b;
    if (m2 >= ER2) { done = 1; }     // ER2 = 4.0 in Q30
    else { ...update z...; n = n + 1; }
}
```

Worst case, end to end: every intermediate is below `2^62`, and after the
update `|x| <= 6.5·ONE` and `|y| <= 8.6·ONE` — nothing after it squares
anything. The arithmetic has no range cliff at all, at any zoom, at any
`--maxit`.

**No cardioid/bulb early-out.** It is the classic speed trick and also three
extra multiplies plus four compares per pixel. `--maxit` is the speed knob
here.

**No `sqrt` in the colouring either.** The smooth term wants `log|z|` and
`|z| = sqrt(zr²+zi²)`, so with `m2` already in hand `log|z| = 0.5·log(m2)` and
the root never has to exist. That matters for more than elegance: `fx.sqrt`'s
input range tops out near `2^33` and `m2` at the moment of escape reaches
`1.3e11`, so a `sqrt` of the raw `m2` would have been out of range. The log
route has no range question at all.

**`ln` is written from scratch**, in 25 lines of `mandel.y`, because Y has no
logarithm anywhere (`fx.y` is trigonometry and roots). Peel the binary
exponent off `x` to leave `m` in `[1,2)`, then atanh's series
`ln(m) = 2(u + u³/3 + u⁵/5 + …)` with `u = (m-1)/(m+1)`, which is at most 1/3
and so loses a factor of nine per term. Eight terms. Measured against IEEE-754
over `x` in `[0.125, 200]`: **6.6e-9 absolute worst case**, which is 3e-9 of
one palette band.

---

## Threading: what it does, and what it honestly does not

`render.y` spawns a bounded pool once, at start-up, and feeds it. Nothing is
spawned per frame or per row: each `spawn` leaks about 128 bytes (measured, and
the reason ORCHESTRATOR.md §2.13 says to feed a pool), so a per-row spawn
would be exactly that mistake at 36 rows a frame.

**Measured speedup**, `refs/ycc.ref`, 20-CPU machine, median of five runs of
**one real frame** — the default view, span 3.6, so a whole Mandelbrot and not a
degenerate one:

| threads | 72×36, maxit 240 | vs 1 | 128×128, maxit 900 | vs 1 |
|---|---|---|---|---|
| 1 | 2.89 ms | 1.00× | 33.25 ms | 1.00× |
| 2 | 1.68 ms | 1.72× | 17.54 ms | 1.90× |
| 4 | 1.46 ms | 1.98× | 11.46 ms | 2.90× |
| 8 (default) | **0.92 ms** | **3.14×** | **9.99 ms** | **3.33×** |
| 16 | 0.70 ms | 4.13× | 7.97 ms | 4.17× |

So: threads help, about **3.1× at the default size with the default 8 workers**,
and about 4.2× at 16. Those are the honest numbers and they are lower than they
look at first, for two reasons worth naming.

**One is the hand-off.** The render is under 3 ms and the frame boundary is a
semaphore wake per worker plus one blocking `wait` on the main side — a futex
round trip each, tens of microseconds a frame. That is a visible fraction of
0.9 ms, and it is the floor the scaling flattens into.

**The other is that a real Mandelbrot frame is not evenly divisible.** Real
frames run from 1 to `--maxit` iterations per pixel, and the rows differ wildly
in cost — the frame ends when its slowest row does, so the work queue is
balancing a very skewed distribution. Contrast this with the degenerate frames
the *headless* `--frames N` mode produces after ~9 frames: at a span of 0.007
centred on −0.6 every pixel is inside the set, every pixel does exactly
`--maxit` iterations, the loop is perfectly predictable, and **those** frames
scale nearly linearly — 9.49 ms at one thread against 1.72 ms at eight, which
is 5.5×. Benchmarking those instead of a real frame would have flattered the
threads by two thirds, which is why the table above is one frame and not forty.

So the honest summary is: **3× at the default size, 4× at 16, on a workload
this small.** The threading is real and worth having — a 128×128 frame at
`--maxit 900` drops from 33 ms to 10 ms, which is the difference between a
keypress and a visible stall — but it is not a 10× machine, and the example
does not pretend otherwise.

**A counting semaphore is not fair**, and that fact dictated the design. The
first version gave worker *w* a fixed band of rows and had the main thread
post *n* tokens and wait for *n*. A semaphore hands a token to whoever asks
first, with no queue behind it, so a worker that comes back round from its
previous iteration while the others are still being scheduled takes a second
token — and can take all of them. Measured on this tree, 8 workers and 3000
rounds of post-8/wait-8: **the total was exactly 8 × 3000 every time**, but the
per-worker split came out `2664 3047 3680 2755 3039 3095 2925 2795` instead of
3000 apiece. With static bands that is not a slow worker, it is an *invisible*
one: seven bands are never rendered, so the grid keeps whatever was in it.
Nothing traps, nothing complains, and the digest is stable from run to run — it
is just somebody else's picture.

So the queue is the design. `ROW_CURSOR` is a mutex-guarded cursor over the
rows and a worker claims `rows/(2·nthreads)` at a time, so every row is claimed
exactly once whatever the wake-up order, a worker that gets an extra token
finds the cursor past the end and does nothing, and a worker that gets no token
costs nothing but idle time because whoever is awake claims its rows. **There
is no shared mutable state per cell and no mutex in the inner loop** — the lock
is taken once per claim, never while a pixel is computed.

Three other things worth knowing, all measured here, all of them mine:

- **A semaphore's count carries over, and that breaks a "finished" signal.**
  The obvious hand-off is "the worker that completes the frame posts a
  semaphore, the main thread waits for it". It posts **more than once a
  frame**, because a worker that wakes to find the queue already empty still
  evaluates `rows_done >= rows`, which is true — the frame *is* done, it just
  does not follow that this frame's wake-up has already been spent. A
  semaphore is a count, so the surplus carries into the next frame, and `wait`
  on a semaphore whose count is already positive returns *at once* — so from
  then on the main thread does not wait for the workers at all and reads the
  grid mid-render. Measured, 8 workers and 40 frames: **23 mismatches in 75
  runs**, where the picture stayed correct (every row is eventually written, and
  by then the view has stopped changing) while `mean-it` came out as
  `333, 2666, 200, 0, 0, 0…` in a run where every frame is 2400. Gating the
  publish on `claimed > 0` makes exactly one post per frame, so exactly one
  wait, so exactly one frame. This was the second time the hand-off bit me and
  it is the reason `render.y`'s comments are as long as they are.
- **`heap_used()` in a spawned thread answers 0.** Each thread allocates from a
  heap of its own, so the global counter never sees it. That is why the heap
  proof below has a second, external measurement.
- **A `lock m { e }` block allocates a closure — 16 bytes, every time.** Ten
  thousand of them cost 160000 bytes; ten thousand `post`/`wait` pairs cost
  **nothing**. Filed as examples/SUGGESTIONS.md §10. The first version of
  `frame()` had the main thread spin on the completion counter under the mutex
  and paid 22 KB a frame — over 1400 lock blocks — plus 1.3 ms of `nanosleep` a
  frame. The shipped version takes **zero locks on the main thread's frame
  path**: the queue is reset with plain stores, completion is a *blocking*
  `wait`, and the totals are read back plainly. The ordering that makes that
  safe is that `post`/`wait` are locked read-modify-writes — full barriers —
  and the reasoning is written out in `frame()`'s comment.

---

## Proving the render allocates nothing

`heap_used()`, main thread, from `--time`:

| run | before | after | delta |
|---|---|---|---|
| `--frames 1 --no-tty` | 2178312 | 2178312 | **0** |
| `--frames 3 --no-tty` | 2178312 | 2178312 | **0** |
| `--frames 200 --no-tty` | 2178312 | 2178312 | **0** |
| `--frames 1000 --no-tty` | 2178312 | 2178312 | **0** |
| `--frames 1000 --no-tty --size 128x128 --maxit 200` | 2178920 | 2178920 | **0** |
| interactive, `--frames 5` under a pty | 2177824 | 2177928 | 104 |
| interactive, `--frames 30` under a pty | 2177824 | 2177928 | 104 |

The interactive 104 is a one-off at start-up, not per frame: five frames and
thirty frames report the same 104.

That covers the main thread only. For the workers, `heap_used()` is blind, so
the check is external — and the address space does not move at all:

```
$ ./mandelbrot --frames 4000 --no-tty --size 128x128 --maxit 200 --threads 8 &
$ for i in 1 2 3 4 5 6 7 8; do awk '/VmSize|VmRSS/' /proc/$pid/status; sleep 3; done
VmSize:  102692 kB     VmRSS:    20620 kB
VmSize:  102692 kB     VmRSS:    20620 kB
... (identical eight times over 24 seconds)
```

Flat `VmSize` is the load-bearing number: a worker that allocated past its
4 MiB chunk would `mmap` another and the address space would step by 4 MiB. The
worker side *does* pay, honestly: one `lock` block per claim is 16 bytes on the
worker's own heap, which for this workload is about 288 KB a worker over a
thousand frames. It never triggers a new chunk, and `heap_used()` cannot see
it — which is exactly why the external number is here.

**How the zero is achieved.** `CELLS` is one module-level `[long; 32768]`
(256 KiB, allocated once at init). `md_shade()` returns a *packed* long —
9 bits of cell, the rest of iteration count — so the statistics reach the
caller without an out-parameter, which would have needed per-thread scratch and
therefore shared mutable state. The 256-entry palette is built once at start-up
and is then a lookup. The render loop contains no array literal, no string, no
record and no closure. The status line's digits go through a module-level
scratch buffer and `fb.put` one cell at a time, because `tostring()` once a
frame would allocate on the frame loop.

---

## The half-pixel that is not cosmetic

Sampling at `cx + dx*(c - cols/2)` puts cell 0 at `-cols/2` steps and the last
at `cols/2 - 1`: the grid sits **half a step off centre**, so a symmetric
picture comes out shifted by half a cell. Measured, a 36-row frame had four
blank rows along the top and none along the bottom, and the set was visibly not
where a reader expects it. Doubling the offset before dividing by two fixes it:

```
yr = cy + dy * ((rows - 1) - 2*r) / 2
xr = cx + dx * (2*c - (cols - 1)) / 2
```

`2c - (cols-1)` is exactly **antisymmetric** — `offset(c) + offset(cols-1-c) =
0`, which is the statement "the picture is symmetric about the origin". `dx`
times an odd number is odd, so the division truncates; but truncation toward
zero is odd-symmetric (`trunc(-x) = -trunc(x)`), so the two halves still cancel
exactly and a frame is mirror-exact about the real axis. The discarded
half-step is `0.5/2^30` of real plane, 5e-10: nothing, and worth saying out
loud rather than hiding.

---

## The `str + byte` segfault

Filed: examples/BUGS.md, *"`str + byte` segfaults"*. Concatenating a string with
a `byte` dereferences the byte's *numeric value* as a pointer. `s[i]` on a `str`
yields a `byte`, so the natural way to build a string from a glyph ramp is
exactly the expression that crashes:

```y
print("x" + "abc"[0]);        // SIGSEGV, exit 139
```

Re-verified against the pinned compiler while writing this. **The workaround
used here is `chr()`**, in `chars_line_row()`:

```y
line = line + chr(mandel.md_glyph(cell, SHD));
```

Two corrections to the brief I was given, both now filed as a second entry in
examples/BUGS.md (*"`'+=' string` rejects a `byte` operand"*):

1. **`line += RAMP[idx]` does not work.** It is a hard compile error, not a
   slow path:
   ```
   3:3: error: '+=' string: expected str, got byte
   ```
   Every source of a `byte` is rejected — `s[i]` on a literal, on a `const`, on
   a `let`, an annotated `byte`, a `[byte]` element. So the existing filing's
   "**Passes** — the compound-assign form, which takes a different emitter
   path" is wrong, and the second sentence of its Cause section rests on a form
   that does not compile.
2. **`chr()` is the only in-language route.** `byte` is in the conversion list
   but there is no implicit `byte` → `str`, and no cast syntax at all.

The shipped default path does **not** concatenate strings at all: it writes
bytes into a fixed `[byte; 65536]` through `textout.y`, which removes the class
of bug rather than routing around one call site, and is what makes
`heap_used()` flat. `--chars` is the deliberate character-by-character
renderer, and it is the one place the workaround lives.

---

## The std units this uses

Vendored, byte-identical to `test/std/`, **not edited**:

| file | sha256 | lines | what this example uses it for |
|---|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` | 694 | `mul`, `fdiv`, `floor`, `from_int`, `abs`, `cos`, `ONE`, `TWO`, `PI`, `TWO_PI` |

All five are byte-identical to `test/std/` as of the last check, and
none was edited here. **The revision moved once while this task ran**, and
deliberately: `fx.y` is still vendored campaign-wide, while `tui` and `args`
now come from std (every folder in
`examples/` now carries the same two shas, `4b47a9bf…` and `95a7663b…`, in
place of the `97c3c02d…` / `741300d7…` this example was briefed with). ORCHESTRATOR.md
§4 calls that the good case — drift should be deliberate, never silent — and the
example was rebuilt from scratch against it. **The behaviour did not change:**
`EXPECTED`, all four golden frames and every digest came out identical before
and after, and the API this example uses is untouched.

Imported by **bare name** — `import fx;` — never `from "./fx.y"`. The path form
parses and then `fb.Surface` fails with `error: unknown type`.

Files written for this example:

| file | lines | what it is |
|---|---|---|
| `mandelbrot.y` | 923 | entry: flags, the view builder, both frame loops, the status line, the deterministic output |
| `mandel.y` | 580 | the set: `ln`, the iteration, the smooth term, cosine palettes, `parse_q30`, the named views, `rnd_unit` (on `std/random.y`) |
| `render.y` | 520 | the worker pool: the work queue, the hand-off, the grid, the digest |
| `textout.y` | 165 | the deterministic byte sink behind `--no-tty` |
| `pty_check.py` | 134 | the interactive harness under a real pty |

---

## Filings

- **examples/BUGS.md** — *"`str + byte` segfaults"*. Re-verified here; the
  workaround is `chr()`.
- **examples/BUGS.md** — *"`'+=' string` rejects a `byte` operand"*. **Added by
  this example.** The existing `str + byte` entry lists `+=` as passing; it is a
  spurious rejection, so that entry's own recommended workaround does not
  compile. Minimal repro, verified matrix and the pass/fail split are in the
  filing.
- **examples/SUGGESTIONS.md §10** — *"`lock m { e }` allocates a closure, so a
  lock is not free on a frame path"*. **Added by this example**, with the
  measured table showing `post`/`wait` free and `lock` 16 bytes. The cost was
  22 KB a frame before this example restructured its hand-off.

---

## No trap on any path

Every one of these exits 0 or 1 with a diagnostic, never with
`runtime error:` — and remember traps print on **stdout**, where they would
corrupt the capture this example is diffed on:

```
--maxit 0                every pixel inside the set: a blank frame, inside = cells
--maxit 1                one iteration per pixel
--threads 0              clamped to 1, inline, no spawn
--threads 1              inline, no spawn, no thread heaps
--threads 9999           clamped to 64, with a note on stderr
--threads -4             via --threads=-4, clamped to 1 with a note
--size 0x0               clamped to 1x1, renders one cell
--size 1x1               one cell
--size 999x999           clamped to 256x128
--seed=-1                normalised into [0, 2^31); the header prints 2147483647
--seed 0                 nudged to 1, so the header never prints a 0 seed
                         (std/random.y has no fixed point to avoid: its seed()
                         offsets the state before the first draw)
--zoom 99                clamped to 48
--maxit 1000001          clamped to 1000000
--dump 99                a frame the run will not reach: dumped frames: none
--palette / --shade / --at / --center junk    a diagnostic naming the accepted
                                              values, exit 1
--bogus, --maxit, --size, --dump with no value    exit 1 from args
an operand                                            exit 1
```

The whole battery, plus `--frames 3000` and `--size 128x128 --maxit 1000000`,
runs clean inside the 3.5 GiB cap.

One real trap was found and fixed while writing this, and it is worth recording
because it was *my* bug and not the compiler's: the `--dump` set was a bitmap,
`want: [long; 1024]`, indexed by the frame number. `--frames 1020` was clean
and `--frames 1040` died on frame 1024 with `runtime error: index out of bounds`
**on stdout**, for every thread count. The set is now the list itself, and
`wanted(f)` is a scan of at most 64 entries — no upper bound to be wrong about.

---

## The interactive path, under a real pty

`tmux` is not installed on this machine, so `pty_check.py` allocates a pty with
`pty.fork()` and sets the window size on it *before* `execv` — a pty from
`pty.fork()` is 0×0, and a renderer that asks for the window would compute a
degenerate frame. It then drives real keys (`l l + + 2 r j - q`), checks the
alt screen was entered and left, and checks the termios it finds afterwards is
byte-for-byte what it was before.

```
$ (ulimit -S -v 3670016; ./pty_check.py) </dev/null
[PASS] exits 0 on 'q'  exit code 0
[PASS] entered the alt screen
[PASS] hid the cursor
[PASS] left the alt screen
[PASS] showed the cursor again
[PASS] emitted truecolour SGR
[PASS] emitted an absolute CUP
[PASS] drew more than one frame  7 home sequences
[PASS] pan/zoom changed the frame  1003 cursor positions emitted
[PASS] termios restored (c_lflag back)  c_lflag before 35387 after 35387
[PASS] echo restored (ECHO|ICANON set)
[PASS] ISIG restored (^C works again)
[PASS] restore is the last thing on the wire
=== pty: 13/13 passed ===
```

`restore_all_exit(0)` is the last call on every path out of the loop, and
`term.arm_watchdog()` is armed **before** the pool starts, so the child it
forks is a copy of a single-threaded process and cannot be holding an inherited
lock.

---

## Known limitations, stated rather than hidden

- **Deep zoom turns to fine texture.** The band is the fractional part of the
  continuous escape time, which is what removes the flat contour steps. But the
  level sets of the escape-time function get closer together than a cell as you
  zoom, so the fraction runs through a whole cycle between neighbouring cells.
  At `--at=seahorse` (span 0.01, 2^8.5) it is already busy; by 2^15 it is
  static. That is what a continuous colouring does when what it is colouring is
  finer than the display. The alternative — banding by the integer iteration
  count — was measured and is worse *everywhere else*: `n % 24` with a ten-step
  dither paints the whole far field blank, because far-field points escape at
  `n = 1` or `2` and those two rings land on the emptiest glyphs. The named
  views are given spans that keep the picture legible, and `--zoom` is the knob
  past them.
- **`--frames` past about 50 gives you the same frame.** Each frame halves the
  span and the Q30 clamp holds it at one step, so after 2^50 the view is
  degenerate and every frame is identical. Not a bug; it is what "halve the
  span" means.
- **`--dump` keeps at most 64 frames** in its list, and the list is what the
  header prints, so `--dump` with more than 64 entries prints the first 64.
- **The palette repeat is 256 bands**, so the smooth term's 6.6e-9 error is
  3e-9 of a band. Nothing to see, and worth knowing.
- **The aspect ratio assumes a cell is twice as tall as it is wide.** The plane
  is walked with `dx = span/cols` and `dy = span/rows`, so a grid that is not
  twice as wide as it is tall shows a set that is stretched to fit — which is
  what every terminal Mandelbrot does, and why the default is 72×36.

---

## The compiler this was built with

```
refs/ycc.ref  sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

**The pin moved during this task**, as warned: the folder started on
`e27f83e4801f9436…` and was rebuilt from scratch against
`c53cc41524a7baa2…`; `EXPECTED` and every measurement above are from the second
build, and `./gate.py mandelbrot` passes 8/8 against it. `refs/ycc.ref` is
built **in place** and never copied — it resolves `std/` relative to its own
path.

Zero warnings, every file, against that pin:

```
$ for f in *.y; do $YCC $f -o /tmp/x 2>&1; done      # no output at all
```
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
