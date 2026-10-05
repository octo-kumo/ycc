# `donut` — Andy Sloane's spinning ASCII torus, in your terminal, at 30 fps

The classic donut: a torus sampled on a fixed grid, rotated by two angles per
frame, projected through a z-buffer and drawn one terminal cell at a time
through a luminance ramp, so it reads as a solid shaded surface rather than a
cloud of dots.

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@@@@%@@@@@@@@@@@@@@@@@@@@@@@@@@
@@@@@@@@@%%%#%##****###%#%%@@@@@@@@
#%@@@@@@%%%#**+=    =+**#%%%@@@@@@@%
%%%%%%%%%%%##*         *#%%%%%%%%%%%
###%%%%%%%%%%%########%%%%%%%%%%%%##*
*######%%%%%%%%%%%%%%%%%%%%%%%#####**
+**###############################**
 +***##########################****=
  +**********###########*********+
   -+++***********************++=
      =+++++*************++++==
```

That is `golden/frame-000.txt` — the face-on pose, hole and all — written to
disk as plain text so you can see the torus without running anything.

---

## Build and run

The folder is self-contained. Everything it needs is in it.

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 e27f83e4801f943668624727b4bc7da70c038600c9d7c2328e4060350f6622f9

(ulimit -S -v 3670016; $YCC donut.y -o donut) </dev/null   # zero warnings

./donut                                # interactive, until q or Escape
./donut --frames 60 --no-tty           # the deterministic run (== EXPECTED)
./donut --color=amber --glyph=blocks   # a phosphor tint on the block ramp
./donut --size 100x40 --fps 60         # a size and a rate
./donut --no-tty --frames 90 --dump 0,17,44    # three frames as text
./donut --frames 300 --no-tty --time   # wall clock, fps and the heap delta
```

`--no-tty` is the path the acceptance gate uses: it renders into a text capture
instead of the terminal, with the terminal's own code path (see *Two paths, one
renderer* below), and never sleeps.

> **Compiler pin, and a moving target.** `examples/ORCHESTRATOR.md`
> quotes this binary's sha256 as `d459af4f08cfffc7…`. While
> this example was being written `refs/ycc.ref` was reblessed **twice** —
> `63a4c3d0691dea43…` at 16:38 and `e27f83e4801f9436…` at 17:33 on 2026-10-04 —
> which is the orchestrator's own point that `refs/` moves only on purpose.
> The **path** is the pin; the hash above is what this example is verified
> against.
>
> Useful evidence about how much that matters: the whole example was built and
> all 300-frame timings taken against `63a4c3d0…`, and then rebuilt from scratch
> against `e27f83e4…` with **zero warnings and byte-identical program output** —
> `./donut --frames 60 --no-tty` still reproduced `EXPECTED` exactly. Nothing in
> this folder depends on a compiler build; `EXPECTED` is a property of the
> maths, and the maths is fx.y's.

### Keys, interactive

| key | what |
|---|---|
| `q`, `Q`, Escape | quit — always through `term.restore_all_exit(0)` |
| `+` / `=` , `-` / `_` | spin speed, 25 % … 400 % of the default |
| space | pause (the status line says `PAUSED`) |
| `r` | back to the face-on pose |

---

## Options

```
  -n, --frames N     render exactly N frames, then exit 0 (default 0: run until q)
  -c, --color VALUE  mono | gray | green | amber | ice
  -g, --glyph VALUE  ascii | blocks | half | braille
  -s, --size VALUE   WxH cells, clamped to 1x1..200x100
  -f, --fps N        frames per second, interactive only (default 30)
  --no-tty           render into a text capture instead of the terminal; never paces
  -d, --dump VALUE   comma-separated frame numbers to print as text beside their digest
  --time             report wall clock, fps and the heap delta on stderr when done
  -h, --help         print this message and exit
```

`--color=mono|gray|green|amber|ice` is spelled and worded to match
`examples/badapple`, which is where the convention comes from: `mono` is classic
white-on-black with the shape carried by the glyph ramp, and `gray`, `green`,
`amber` and `ice` are the same luminance fit on a phosphor tint. An unknown
value is a message on stderr and exit 1; stdout stays clean.

`--size` is **clamped, never refused**: `--size 0x0` renders one cell and exits
0 rather than dividing by zero somewhere in the projection. `--frames 0` with
`--no-tty` renders one frame, because that path has nothing else to stop it.

Exit codes: `0` ran (or `--help`), `1` a bad option, a bad value, or a stray
operand.

---

## What to look at when you run it

1. **The hole closes and opens.** Frame 0 is the ring seen face-on; about 45
   frames later the torus is nearly edge-on and the hole has gone. Both are in
   `golden/`.
2. **`bytes` in the `--no-tty` digest.** The first frame emits ~2 700 bytes of
   ANSI and a settled frame ~300. That is `fb.flush_diff` finding the maximal
   runs of changed cells: an unchanged row costs nothing at all. It is the whole
   reason 30 fps is affordable — a full repaint every frame would be 60× the
   traffic.
3. **`dots` and `clip`.** `dots` is the subpixels the surface won (of
   `2*cols × 4*rows`); `clip` is samples that projected outside the frame.
   **`clip` is 0 in every frame at every size tested** — see *The framing is
   measured, not guessed*.
4. **The status line.** Frame counter, measured fps, the colour mode, the spin
   rate. Press space and it says `PAUSED`; press `+` and the spin rate climbs.
5. **`--glyph=braille`.** Same renderer, but the cell is used as what it is — a
   2×4 dot bitmap — and the picture gets twice the horizontal and four times the
   vertical resolution of the ascii ramp.

---

## How it works

### The geometry (`torus.y`)

A point of the torus with `R1 = 1`, `R2 = 2`, at angles `(θ, φ)`:

```
P = ((R2 + cosθ)·cosφ,  (R2 + cosθ)·sinφ,  sinθ)
```

rotated by `B` about z and then by `A` about x, projected as `x/(z+K2)`.
Folding `φ + B` first — because `Rz(B)` turns the pair
`((R2+cosθ)cosφ, (R2+cosθ)sinφ)` into `((R2+cosθ)cos(φ+B), (R2+cosθ)sin(φ+B))`
*exactly* — collapses the whole frame to four multiplies a sample:

```
X = (R2 + cosθ)·cos(φ+B)                      <- already in Q30
Y = (R2 + cosθ)·sin(φ+B)
y = Y·cosA − sinθ·sinA                         <- the rotation about x
z = Y·sinA + sinθ·cosA
```

and then the projection is two plain integer operations, `(x·scl)/den` with
`den = z + K2`, because `scl` is kept an integer rather than a Q30 constant.
That is the load-bearing decision of this file: it keeps the hot loop off the
fixed-point path entirely.

**Why there is no trigonometry in the inner loop.** The torus is sampled on a
*fixed* `na × nb` grid of `(θ, φ)`, so `cos` and `sin` of those angles never
change between frames — only `A` and `B` move. So they are a start-up table
(`CT`, `ST`, `CF`, `SF`, `WI`), the per-frame job is four `fx.sin`/`fx.cos`
calls plus one rotation of the `j` and `i` tables (`CR`, `SR`, `AS`, `AC`), and
a sample costs four `fx.mul`s. 22 801 samples a frame at 60×24.

**The luminance is free.** The surface normal is
`(cosθ·cosψ, cosθ·sinψ, sinθ)`, and carried through the same two rotations it
lands on `(nx, y, z)` with `ny = y` and `nz = z`. Lit from `(0, 1, −1)` —
Sloane's light — the dot product is therefore just

```
L = ny − nz = y − z
```

which the projection had already computed. So the shading costs no normal, no
extra rotation and no `sqrt`; it is one subtract and one integer divide:

```
lum = ((y − z + √2) · 128) / √2        // 0..256
```

### The subpixel grid, and what keys the glyph

A terminal cell is about twice as tall as it is wide, so **square** subpixels are
**2 across by 4 down** a cell — exactly the braille geometry. One cell is eight
subpixels, each with its own z-buffer entry, so a cell is 2× horizontal and 4×
vertical resolution against the ascii ramp. At 60×24 that is a 120 × 96
subpixel grid, and `na = nb = isqrt(2·120·96) = 151` samples per axis — about two
samples per subpixel, which is the density at which the coverage of a cell is
essentially complete.

Two different things want the glyph, and the choice is made in `torus_draw`:

- **ascii / blocks / half** — the glyph is the **luminance** of the nearest
  subpixel the surface won. This is the classic donut, and it is what a ramp is
  for: the ramp steps *are* an intensity scale. Coverage would be wrong here —
  inside the silhouette coverage saturates at 8 of 8, so every cell in the body
  of the torus would come out as the same full block.
- **braille** — the glyph is the **coverage** of the eight dots, one bit each,
  which is the whole point of a 2×4 dot cell: it is a bitmap, not a shade.

Either way the colour is the same luminance, so the tinted modes shade the
surface continuously while ascii puts the shading in the glyph.

### The framing is measured, not guessed

The worst value of `|x/(z+K2)|` over the surface depends on the orientation — a
torus seen edge-on projects further than one seen face-on — so a hard-coded
scale constant either clips at one angle or leaves the donut tiny at another.
Instead `torus_setup` **measures** it: 24 orientations of `A` against a strided
sample of the grid, taking the largest `|x/(z+K2)|` and `|y/(z+K2)|` seen, and
solves for the scale that puts 46 % of the smaller side at that extent. A few
thousand iterations, once, at start-up and after a resize.

The payoff is measurable and is printed every frame: **`clip` is 0 in all 300
frames at 60×24 and at 200×100** — not one sample in fifteen thousand, over a
whole turn, projects outside the frame.

The trade is honest: because the scale is sized for the *worst* orientation, the
torus is smaller than it could safely be when it is face-on. That is the price
of never clipping.

### Two paths, one renderer

`--no-tty` is not a separate renderer. It draws into the same `fb.Surface` and
calls the same `fb.flush_diff`, and only changes where the bytes go: the ANSI
stream is written to `/dev/null` (`fb.set_fd`) and the text goes to stdout
through `textout.y`. That is what makes the `bytes` column in the digest a real
measurement of the interactive path rather than a claim about it.

`--no-tty` also **never paces**. That path exists to answer "how fast can this
machine draw frames", and a sleep in the middle of it would measure
`nanosleep` instead. `--fps` is an interactive knob.

### The frame loop allocates nothing

Proven, not asserted. `--time` prints `heap_used()` before and after:

```
$ ./donut --frames 300 --no-tty --time
donut: 300 frames in 235357 us = 235 ms -> 127.55 fps
donut: heap_used before=4507440 after=4507440 delta=0
```

and the interactive path reports the same on its way out:

```
donut: 120 frames, 43 KiB of ANSI in total, 368 bytes a frame,
       measured 29 fps, heap_used 4507368 -> 4507368 delta 0
```

(`29` there is `time.fps_new`'s half-second window closing on a frame boundary,
not the rate; the wall clock around that same run is 4.003 s for 120 frames,
which is 30.0 fps. The windowed meter is optimistic by up to one frame in
either direction and is there so a human watching can see a stall.)

Three things had to be moved out of the frame path to get there, and all three
are the same trap — **a literal inside a loop body is evaluated onto the heap
every iteration**, 64 bytes for a five-field record and 72 for `[long; 12]`,
while nothing is ever freed:

| was | now |
|---|---|
| `pal()` built a record literal and passed it to `torus_draw` every frame | `torus.torus_palette(...)` writes one module-level record, once |
| `sline()` declared `let d: [long; 12] = [48, 48, …]` — six times a frame | `DIG`, a module-level array, re-bound (`let d = DIG`, which is free) |
| the resize poll called `term.size()`, which **returns** a record | `poll_winsize()` does `TIOCGWINSZ` into a byte buffer of our own and decodes it with `term.rd16` — same answer, zero bytes of heap |

`textout.out_num` has the same shape of problem for a different reason: its
digit scratch is module level, because a `[long; 24]` literal inside a function
called 300 times would leak 21 kB.

Everything else on the frame path was checked rather than assumed: `fb.put`,
`fb.flush_diff`, `fb.text`, `fb.lerp_rgb`, `syscall`, `time.now_us` and
`time.pacer_next` all measure a heap delta of 0 over a thousand calls.
`term.size()` is the exception, and it is in the table above precisely because
it is *not* — it answers with a record.

---

## Re-running the gate

```sh
cd examples/donut
(ulimit -S -v 3670016; sh gate.sh) </dev/null     # prints [1]..[7], ends GATE: PASS
```

`gate.sh` runs all seven acceptance items: the zero-warning compile, three
deterministic runs plus the `EXPECTED` comparison, **33 invocations checking
that no path traps** (including `--help`, every bad flag, `--size 0x0`,
`--size 1x1`, `--frames 0`, a stray operand and every colour/glyph pair), the
300-frame heap delta, the wall clock, `pty_check.py`, and a standalone rebuild
into `mktemp -d` compared byte for byte. It honours `YCC=` if you want to pin a
different compiler.

---

## Measured performance

`--no-tty --frames 300 --time`, one row per size. The fps column is the
**observed range over repeated runs** on this shared machine, so the spread is
other agents' load as much as anything:

| size | cells | samples/frame | fps (observed range) | heap delta |
|---|---|---|---|---|
| 60×24 (the `--no-tty` default) | 1 440 | 22 801 | **125.6 – 128.4** | 0 |
| 80×24 (a typical terminal) | 1 920 | 28 900 | **95.7 – 96.9** | 0 |
| 100×40 | 4 000 | 64 000 | **40.5 – 48.8** | 0 |
| 120×40 | 4 800 | 76 729 | **35.1 – 39.6** | 0 |
| 160×50 | 8 000 | 113 137 | 21.9 – 23.6 | 0 |
| 200×100 (the size cap) | 20 000 | 160 000 | 16.6 – 17.5 | 0 |

Ranges are across repeated runs on a **shared** machine, so the spread is
load, not the program. The 60×24 figure is the number to quote: **300 frames
in 234 ms, 128 fps**.

**30 fps holds up to about 120×40 cells**, which is most terminals. Past that
the renderer cannot keep up and `tui`'s pacer does what it is built to do:
drop the frame, keep the absolute schedule, and let the rate recover. The
status line's fps meter shows the truth when that happens. The interactive run
at 80×24 measured **30.0 fps** over 120 frames (4.003 s wall clock).

---

## Two paths, three test harnesses

`pty_check.py` is in the folder and is how the interactive path is verified
without tmux (which is not installed on this machine). It allocates a pty,
sets the window size **before** `execv` (a pty from `pty.fork()` is 0×0, and
`TIOCGWINSZ` would otherwise report nothing), waits for the alt screen, types
`q`, and then checks the terminal was handed back:

```python
import fcntl, os, pty, select, struct, sys, termios, time

argv = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.execv(argv[0], argv)

before = termios.tcgetattr(fd)
out = b""
while b"?1049l" not in out:
    r, _, _ = select.select([fd], [], [], 0.25)
    if r:
        try: out += os.read(fd, 65536)
        except OSError: break
    if b"?1049h" in out and not sent:
        os.write(fd, b"q"); sent = True
after = termios.tcgetattr(fd)
_, status = os.waitpid(pid, 0)
```

```
$ python3 pty_check.py ./donut
alt screen entered      : True
alt screen left         : True
cursor hidden / shown   : True / True
c_lflag before / after  : 0x8a3b 0x8a3b
cooked mode restored    : True
exit status             : 0
RESULT                  : PASS
```

`c_lflag` identical before and after is the load-bearing line: the terminal came
back in cooked mode, so the shell has its echo and its Ctrl-C. It has to hold
even when nothing in the program gets a chance to run — which is what
`term.arm_watchdog()` is for, a forked child blocked on a self-pipe with
`setsid`, restoring the saved termios the instant the parent's pipe closes.
Measured, by capturing the termios *while* the program is running and then
`kill -9`-ing it:

```
  lflag running         : 0xa20   ICANON off = True      <- raw mode held
  lflag after SIGKILL   : 0x8a3b  ICANON on  = True      <- the watchdog wrote it back
  ECHO restored         : True
  identical to cooked   : True
```

The keys were checked the same way, by rebuilding the status row out of the
CUPs the frame wrote: `space` puts `PAUSED` in the row, `+` walks the spin rate
100 → 125 → … → 400 %, `-` walks it back down to 25 %, `r` returns to the
face-on pose, and `q` **or** Escape exits 0 with the terminal restored.

---

## The deterministic run

`./donut --frames 60 --no-tty` writes to **stdout only** — 6 665 bytes, no
escape sequences anywhere in it — and is byte-identical across runs. Its shape:

```
donut: frames=60 size=60x24 glyph=ascii color=mono samples=22801
dumped frames: 59
frame    0 bytes     2669 rows    24 dots    11429 clip       0 sha 521bb5070dd56eb4
frame    1 bytes      419 rows    13 dots    11325 clip       0 sha cb7b8766e1e78fba
...
frame   59 bytes      200 rows     9 dots     7225 clip       0 sha 1d5bbda5e08f67de
--- frame 59 ---
                     ...the picture...
```

`EXPECTED` is that run, byte for byte. The per-frame `sha` is an FNV-1a over
every cell's codepoint **and** foreground colour (`textout.grid_digest`), so it
changes if the shape changes *or* if only a colour changes — which is why it is
evidence rather than decoration. Nothing time-dependent appears on this path:
the wall clock and the heap delta go to **stderr** under `--time`.

Nothing about the run depends on the terminal, the clock, the heap layout or a
random seed. `--size` defaults to a fixed 60×24 when there is no terminal to
ask, which is what makes it reproducible on a machine whose window is a
different shape.

---

## Files

| file | lines | what |
|---|---|---|
| `donut.y` | 561 | CLI, palettes, status line, both frame loops |
| `torus.y` | 428 | the geometry: trig tables, rasteriser, cell pass, framing |
| `textout.y` | 173 | the deterministic sink: fixed byte buffer, FNV digest, text frames |
| `EXPECTED` | 88 | `./donut --frames 60 --no-tty`, byte for byte |
| `pty_check.py` | 101 | the pty harness for the interactive path |
| `gate.sh` | 105 | the whole acceptance gate, re-runnable: `sh gate.sh` |
| `golden/frame-000.txt` | 35 | face on — the iconic ring |
| `golden/frame-012.txt` | 35 | tilted — the shading wraps, the hole almost closed |
| `golden/frame-045.txt` | 35 | nearly edge on — the torus seen from its own plane |

## The std units this uses

Vendored byte-identical from `examples/_toolkit/` and **not edited** (the folder
contract, `ORCHESTRATOR.md` §4):

| file | sha256 prefix | lines |
|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 |

Re-verify with:

```sh
cd examples/donut && sha256sum fx.y tui tui tui args
```

Every toolkit call this example makes: `fx.mul` `fx.cos` `fx.sin` `fx.abs`
`fx.isqrt` `fx.ONE` `fx.TWO_PI` `fx.wrap_2pi` · `fb.new` `fb.resize` `fb.put`
`fb.text` `fb.flush_diff` `fb.frame_bytes` `fb.row_count` `fb.set_fd`
`fb.capture_on` `fb.capture_reset` `fb.rgb` `fb.lerp_rgb` `fb.shade_ascii`
`fb.shade_blocks` `fb.shade_half` `fb.braille_cp` `fb.braille_mask`
`fb.utf8_len` `fb.utf8_byte` `fb.Surface` · `term.raw_mode` `term.enter_screen`
`term.arm_watchdog` `term.restore_all_exit` `term.size` `term.read_key_timeout`
`term.TIOCGWINSZ` `term.rd16` `term.KEY_ESC` · `time.now_us` `time.pacer_new`
`time.pacer_start` `time.pacer_next` `time.fps_new` `time.fps_tick`
`time.fps_x100` · `args.init` `args.parse` `args.get_str` `args.get_long`
`args.has` `args.positional` `args.num_ok` `args.usage` `args.Opt` `args.NUM`
`args.STR` `args.BOOL` `args.HELP` `args.USAGE`.

---

## Workarounds, and where they are filed

One finding, filed in `examples/SUGGESTIONS.md`:

**§6 "A literal in a loop body allocates every iteration".** A record or array
literal evaluated inside a loop is put on the heap each time — 64 bytes for a
five-field record, 72 for `[long; 12]` — even though it does not escape and
nothing is ever freed. There is no way to write one on the stack. This is what
forced the palette into a module-level record, `DIG` out of `sline`, and the
resize poll off `term.size()`. The workarounds are visible in the code and
commented where they appear; nothing else about this example is shaped by a
compiler bug.

Nothing here is a miscompilation. The three language gaps that shape a program
like this — no `float`→`long` and no casts, no `sin`/`cos`, no `break` — are
known, deliberate and already in the ledgers (`ORCHESTRATOR.md` §2.4, root
`TODO.md`); this example routes around all of them without filing anything new.

---

## Honest notes

- **The status line carries measured timings, so it is not in the deterministic
  output.** `--no-tty` renders into the whole surface and prints no HUD, because
  a HUD with a frame rate in it could not be byte-identical between runs.
- **`fb.shade_ascii(v, 256)` maps luminance onto its 10-level ramp as
  `v·10/256`,** so the ramp's `-` (index 4) is never reached and `@` needs a
  luminance above 231/256. That is the toolkit's ramp granularity, not a
  bug — `ramp_index` is monotonic by construction, which is the property that
  matters.
- **The torus is deliberately smaller than it could safely be** so that no
  orientation ever clips. See *The framing is measured, not guessed*.
- **`--no-tty` output is not meant to be read as animation.** It is a digest and
  a few frames, so it diffs. The animation is the terminal path.
- **Sizes are capped at 200×100**, below `fb`'s own 256×128, so the subpixel
  buffers (`2 × 160 000` longs, 2.5 MiB) are allocated once and never grown. The
  heap at start-up is about 4.5 MB and it does not move.
## Pin re-verification: `625efd81` (orchestrator, 2026-10-05)

The compiler pin moved while this example was being built and has moved
again since (`refs/` keeps only the current binary, so earlier pins cannot
be recovered). As of the orchestrator's last gate run this example was
re-verified against `refs/ycc.ref` sha256

```
c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

and it is unchanged in substance: it compiles with **zero warnings** and
its `gate.conf` `run=` line still reproduces `EXPECTED` byte for byte.

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
