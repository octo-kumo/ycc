# `cube` — a rotating cube in your terminal

A wireframe-and-shaded-solid 3D cube, perspective projected, 30 fps, no
floating point anywhere. Eight vertices, twelve edges, six faces, a light,
and an optional floor grid.

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref     # sha256 c53cc41524a7baa2…
(ulimit -S -v 3670016; $YCC cube.y -o cube) </dev/null

./cube                      # interactive: alt screen, q or Esc to quit
./cube --solid --color=ice  # shaded solid, phosphor blue
./cube --floor              # …and a perspective floor grid
./cube --frames 60 --no-tty # plain text on stdout, diffable against EXPECTED
./cube --selftest 60        # the correctness checks; exit 0 or 1, no terminal needed
```

## What it is

Two angles — yaw at 6° a frame, pitch at 3° — rotate the cube about Y and
then about X. Both are a **pure function of the frame number**, so frame 37
of any run is frame 37 of every run, and the whole animation is a pure
function of `--frames`. Each of the 8 vertices is rotated, given a depth from
the eye, projected to a cell, and drawn; each of the 6 face normals is
rotated by the *same* four products, and a face is drawn exactly when its
rotated normal points back at the camera.

Three faces survive that test for any generic angle, which is what the brief
asked for: **back-face culling, no z-buffer.** In wireframe the culling is
used differently — an edge is drawn bright if at least one of its two
adjacent faces survived, dim if both were culled, so the hidden edges are
hidden. In solid mode the three front faces are filled in painter's order
(farthest first, by the face normal's z) and the visible faces' outline goes
on top.

Face brightness is Lambert: `v = max(dot(normal, light), ambient)` mapped to
0..255 and through `fb.shade_blocks`, with a darker companion colour for the
background so a face reads as a surface rather than as a patch. The light is
the unit vector `(-5, 7, 11)/sqrt(195)` **in view space**, so it stays put
while the cube turns under it and the faces brighten and darken as they come
round.

## Two rendering defects this shipped with, and the checks that now own them

**Read this before trusting any golden file, including this one.** The first
revision of this example passed every mechanical gate — zero warnings,
byte-identical output three times running, no trap on any of 22 argument
combinations, 30 fps, `heap_used()` delta 0 — and drew two things wrong:

1. **A wireframe that filled regions.** `draw_floor()` was called
   unconditionally in both modes, so every frame carried a second subject.
   Its rungs are one world unit apart, which is under a cell near the
   camera, so they merged into a stipple, and between the cube's screen
   bounding box (which the floor skips) and the edge of the screen that
   stipple was a **filled triangular wedge**. It was deterministic, so
   `cmp EXPECTED EXPECTED` was happy forever.
2. **Diagonal edges drawn as straight runs.** `seg()` picked the dominant
   axis of an edge and drew one `fb.hline` or `fb.vline` along it. For an
   edge with |dx| ≈ |dy| that draws a straight line the edge does not follow,
   so the picture filled up with **floating runs that joined nothing** — most
   of them in frame 9, where nine of the twelve edges are diagonal.

Both are fixed: the floor is `--floor` and off by default, and `seg()` walks
a staircase along the segment whenever it is not axis-aligned. Both are now
caught by `./cube --selftest N`, which is the part worth having.

### What the self-test checks, and why it is worth more than a golden file

`--selftest N` runs two checks over N frames, draws into the surface and
reads it back, needs no terminal, and exits 0 or 1.

| | property | oracle | measured | a defect measures |
|---|---|---|---|---|
| **T1** | in wireframe, **no cell is drawn that is not on a projected edge** | each of the 12 projected edges walked with an integer DDA — *not* `seg()`'s primitive — accepting a cell within 1 of the staircase | **0** cells off an edge, 167 cells drawn in the busiest frame | 369 with the floor on; **77** with the old dominant-axis `seg()` |
| **T2** | in solid, **the fill is the projected quad, not its bounding box** | point-in-convex-quad on four cross products — nothing like `fill_face()`'s scanline spans | **1** cell of overhang | **9** with `fill_face` walking the bounding box |

Both oracles are computed a *different way* from the code they check, which
is the whole point: a check that mirrors the implementation cannot find an
implementation bug. T2 reports a **distance** rather than a yes/no, because a
scanline fill of a polygon whose own vertices are rounded to cells can put an
extreme cell one cell outside the true edge, and a thin face's rounding can
make one vertex slightly reflex — the check is quantitative and prints the
number, rather than a threshold tuned until it passes.

Verified with three defect injections, each rebuilt from this exact source:

```
defect injected                                T1 worst   T2 worst   exit
(none) -- the code as shipped                     0          1         0
draw_floor() forced on, decimation removed       369          9         1
fill_face() walking the bounding box               0          9         1
seg() back to a dominant-axis run                  77          1         1
```

## What to look at

* **Every edge meets every other edge.** `golden/wire.txt` has no floating
  segments and no dotted regions: each of the twelve edges is a connected
  path corner to corner. That is T1, and it is the thing a golden file
  cannot show you.
* **The faces are trapezoids, not rectangles.** In `golden/solid.txt` at
  frame 15 the top face's left edge steps one cell left per row and its
  right edge one cell right; the lower face does the opposite. At that angle
  (yaw 90°, pitch 45°) the shared edge between the two visible faces projects
  as an exact horizontal line, which is correct and looks like a straight
  division until you count the slanted outer edges.
* **`yaw` and `pitch` in the header.** `--no-tty` prints them in tenths of a
  degree, zero-padded to four so 90 and 900 are distinguishable, and rounded
  — the round is there because two Q30 products turn 6° into 5.99985, and a
  header that said 5.99 would be lying about a frame you can count.
* **The floor, if you turn it on.** `--floor` is off by default because it is
  a second subject and a wireframe renders one; with it on it is decimated to
  `FLOOR_GAP` rows apart so it reads as a grid rather than saturating near
  the camera, and its cells inside the cube's screen bounding box are skipped
  so the cube occludes it without a z-buffer. `golden/floor.txt`.
* **`heap_used()` under `--stats`.** Printed before and after the frame loop
  and the delta is **0**, from 100 to 3000 frames. Checkable, not claimed.

## Options

| flag | meaning |
|---|---|
| `-n, --frames N` | render exactly N frames, then exit 0. Default 0 = run until a key. |
| `--solid` | fill the three front faces with shading. Default is wireframe. |
| `-w, --wireframe` | edges only, hidden ones dimmed. The default; wins over `--solid` if both are given. |
| `--floor` | also draw the perspective floor grid. **Off by default.** |
| `-c, --color VALUE` | `mono` (default), `gray`, `green`, `amber`, `ice`. |
| `--size WxH` | cells. Default the window, or **24 rows × 60 columns** with `--no-tty`. Clamped to 128×256. |
| `-f, --fps N` | frames per second; `0` = as fast as possible. Default 30, or **0** with `--no-tty`. |
| `--no-tty` | write plain text to stdout instead of drawing to the terminal. |
| `--selftest N` | run T1 and T2 over N frames, then exit. Absent or 0 = off. |
| `--stats` | timings, measured rate and the heap delta, to **stderr**. |
| `-h, --help` | the generated usage, exit 0. |

`--color` mirrors `examples/badapple`: the same five spellings, `mono` as the
default. `mono` is the safe one — it uses `fb.DEFAULT` for every colour and
prints the glyphs as ASCII `-`, `|`, `+`, so it needs no font beyond ASCII.
The other four are truecolor: `gray` is `fb.grey(v)`, and `green`/`amber`/
`ice` are the same brightness curve on a phosphor tint. The colour mode
changes the *glyphs* too: the non-`mono` modes draw with U+2500 box
characters, which look better but need a font that has them.

Unknown `--options` are rejected by `args` with a message on stderr; this
program then exits **1** (rather than `args`'s own convention of 2).
`--color=chartreuse`, a malformed `--size` and a stray operand are rejected
the same way, with the same exit code.

### Keys (interactive only)

| key | |
|---|---|
| `q`, `Esc`, `^C` | quit, restoring the terminal |
| `s` | toggle solid / wireframe |
| `c` | next colour mode |

### The plain-text path

`--no-tty` renders into the **same** `fb.Surface` the terminal path draws
into and then reads the cells back, one header line and `ROWS` lines per
frame. That is why the two paths cannot drift apart. The glyphs come from
`fb.shade_ascii`, so the output is pure printable ASCII and `EXPECTED` is a
text file a human can read — a text file cannot carry a colour, so the colour
mode shows up in the header and nowhere else. That is the honest limit, not a
missing feature.

`--no-tty` also **does not pace** unless you ask (`--fps 30`), because the
output is a file rather than an animation and `--frames 60` should not take
two seconds to produce 91 KB of text.

## Build, run, verify

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
# sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
(ulimit -S -v 3670016; $YCC cube.y -o cube) </dev/null      # zero warnings

# the two correctness checks -- no terminal, exits 0 or 1
./cube --selftest 60
#   T1 wireframe: most cells drawn in one frame 167, most cells off a projected edge 0
#   T2 solid:     most cells outside a front face's quad, in cells 1 (...)
#   RESULT PASS

# the deterministic run, three times, byte-identical
for i in 1 2 3; do (ulimit -S -v 3670016; ./cube --frames 60 --no-tty) </dev/null > /tmp/r$i; done
cmp /tmp/r1 /tmp/r2 && cmp /tmp/r1 /tmp/r3 && cmp /tmp/r1 EXPECTED

# the interactive path, under a real pty (no tmux on this machine)
python3 cube_pty_check.py ./cube                 # types 'q', expects exit 0
PTY_KEY_HEX=1b python3 cube_pty_check.py ./cube # Escape
PTY_KEY_HEX=03 python3 cube_pty_check.py ./cube # ^C
PTY_ROWS=40 PTY_COLS=120 python3 cube_pty_check.py ./cube --frames 300 --stats

# a resize mid-run: 60 -> 84 columns at t=1.2 s, 'q' at t=3 s
PTY_ROWS=40 PTY_COLS=60 PTY_RESIZE=1.2 PTY_KEY_HEX=71 PTY_DELAY=3.0 \
  python3 cube_pty_check.py ./cube
#   widest column   : 82 OK (window was 60 cols before the resize)
```

`EXPECTED` is the exact stdout of `./cube --frames 60 --no-tty`, 1500 lines /
91 080 bytes, sha256 `9a28b9ffab1c37d5…`.

**`EXPECTED` is a regression file, not a proof.** It pins the bytes so a
change shows up in a diff. Whether the bytes are *right* is `--selftest`'s
job, and the two defects above are the proof that the distinction matters.

### The terminal is never left broken

`run_tty` follows `tui`'s pattern exactly: `raw_mode()`, then
`enter_screen()`, then **`arm_watchdog()` before the first frame**, and every
way out ends in `term.restore_all_exit(0)`. Verified under a pty with `q`,
with a bare `Escape`, and with `^C`: exit 0, `ESC[?1049h` seen, `ESC[?1049l`
seen, `ESC[?25l` seen, `ESC[?25h` seen. A resize mid-run is picked up on the
next frame with no allocation (`fb.resize` is a field write plus a shadow
reset).

`SIGKILL` is the one path the watchdog cannot fully cover and it says so:
after a `kill -9` the forked watchdog restores the **termios**, but the alt
screen and the cursor are emulator state that only a write to fd 1 could put
back and the watchdog closes fd 1 first. That is `tui`'s documented limit
(`tui.y:1194-1199`), not a gap in this program — the alt screen is emulator
state you cannot reach after your own descriptor is gone.

## Compiler workarounds

Everything here is a workaround for something the language does not have, or
does not have where you want it. Nothing needed a compiler patch.

| what | why | where |
|---|---|---|
| **Q30 fixed point for all the geometry.** `fx.sin(fx.to_rad(fx.from_int(6)))`, not `fx.sin(fx.to_rad(6))` | Y has no `float` → `long` and **no cast syntax at all** (`ORCHESTRATOR.md` §2.4a). `to_rad` multiplies a *Q30* value, so `fx.to_rad(6)` is `mul(6, 18740330) >> 30` = **0**, silently. `fx.from_int` on the way in is the whole difference between a rotating cube and a static one. | `draw_frame`, top of file |
| **The focal length is a PIXEL count, not a Q30 angle.** `offset = (coord_Q30 * focal_px) / depth_Q30` | The Q30 factors cancel, so the quotient is already a whole number of cells. A Q30 focal length (what `fx.mul` wants) forms a product near 2^65 and saturates — which is *also* silent, it just clamps. | `project()`, `floor_x()`, `floor_y()` |
| **`term.size()` is not called once a frame** — the program does the `TIOCGWINSZ` ioctl into its own `[byte; 64]` | `term.size()` builds a **fresh `WinSize` record per call**: 40 bytes a frame at 30 fps, in a program whose claim is that the loop allocates nothing. Measured: `+12000 bytes over 300 frames` before the change, `+0` after. | `poll_size()`, and the comment on `WSZ` |
| **`read_key_timeout(0)`, not `(10)`** | `read_key_timeout` rounds up to whole **deciseconds**, so `(10)` is a 100 ms wait — three frame times at 30 fps. Using it as a key handler capped the loop at 10 fps and made the pacer drop every frame. `0` is a pure poll and the pacer owns the waiting. | `run_tty` |
| **`let late: long = 0;` before the pacer, not `-1`** | "was this frame dropped" has to start at *no* for the unpaced case. Seeded at -1 (thinking "a late frame is the safe default") `--fps 0` drew **nothing at all** and sat in the alt screen emitting two escape runs forever. Caught by running `--fps 0` rather than by reading the code. | `run_tty` |
| **`c'q'`, never `'q'`** | A Y character literal is `c'q'`; a bare `'q'` is not syntax. The second bare apostrophe in a file turns a positional error into a position-less `error: unterminated string literal`. Filed: [`examples/BUGS.md` → `'a'` is not a character literal](../BUGS.md). | `K_Q`, `K_S`, `K_C`, `K_CTRL_C` |
| **Guard-flag early exits, no `break`/`continue`** | `break` and `continue` are undefined names (§2.9). The quad fill keeps a `got` flag; the face sort's shift condition *is* the loop condition; `z_depth` clamps instead of bailing; `on_edge` tests `!hit` in its loop condition. | `fill_face`, `draw_frame`, `on_edge` |
| **Fixed top-level arrays for every per-frame buffer** | The heap is an arena and nothing is ever freed (§2.7): `PX/PY/PZ/SX/SY/NZ/FRONT/FORD`, plus one `fb.Surface` (1.5 MiB) that is the only heap the program owns. | the state section |
| **`c'-'` / `c'|'` / `c'+'` for the ASCII glyphs, numbers for the Unicode ones** | a `char` literal is a `byte`, so each needs an explicit `long` annotation; and a non-ASCII `c'─'` would be three bytes, not a codepoint. | `G_H`, `edge_*_glyph` |

### The divide guard, which the brief called the most likely trap

Every division in this file is either by a compile-time constant or by a
**depth that has been clamped first**, in one place:

```
// z_depth(z) -- the distance from the eye to a point whose view-space z is z.
def z_depth(z: long) -> long {
    let d = CAM_DIST - z;
    if (d < MIN_DEPTH) { d = MIN_DEPTH; };
    d
};
```

`MIN_DEPTH` is `1.0` in Q30, so **the divisor is never 0** on any path. The
clamp never actually fires: the camera is 6 units out on +z and the closest
anything in this scene comes to it is the floor's near rail at `z = 2`, a
depth of 4.0. It is there so that no future geometry, no `--size` and no
resize can reach the divide, because division by zero is a *runtime trap that
prints on stdout* (§2.6) — in the middle of a frame, into a diff.

The other divides are guarded at the point of division:

* the quad fill's `(x1 - x0) * (y - y0) / (y1 - y0)` — the edge scan skips
  an edge whose two ends share a row (`if (ya != yb)`), which is both the
  correct thing to do for a horizontal edge and the guard;
* `dline`'s and `seg`'s `(dx * i) / steps` — the loop only divides when
  `steps > 0`, and `steps` is the larger of the two spans;
* the self-test's `quad_over` divides by nothing; `report`'s `DRAW_US / got`
  is guarded at the call, since `got` can be 0.

`--size 0x0`, `--size 1x1` and `--size 9999x9999` all clamp to something
drawable and exit 0; nothing out of range reaches an index, because `fb.put`
ignores an out-of-range cell and every index into a fixed array is written
with the loop bound in the type.

## Numbers, measured on this machine

**Zero warnings** with the compiler's default warning set. (`-W 1`, which is
an opt-in extra and not part of the gate, additionally reports *dropped call
results* — the rest inside std `tui` and `args`,
every one a `fb.put`/`fb.hline`/`fb.vline`/`fb.clear`/`fb.flush_diff` whose
cell count nobody wants. A vendored toolkit can never be `-W 1` clean, so
those nine are left alone rather than dressed up with discards.)

Compiler: `refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.

> **Note on the pin.** `ORCHESTRATOR.md` §3 and the Wave 1 brief record this
> compiler as `d459af4f08cfffc7…`. `refs/ycc.ref` moved **twice** while this
> example was being written (other waves are reblessing), so three hashes are
> in play: `d459af4f…` (the brief), `63a4c3d0…` (what the first round of
> measurements was taken against, and the hash in the `BUGS.md` entry this
> example filed) and `c53cc415…` (what the tree holds now). The example was
> re-verified against the third — zero warnings, `EXPECTED` reproduces byte
> for byte, the interactive path exits 0 at 29.99 fps under a pty — so it is
> stable across two compiler revisions. Nothing else is ever substituted for
> the pin.

**30 fps holds, with three orders of magnitude to spare.**

| geometry | mode | 300 frames, rate | work a frame | of the budget | wall | heap |
|---|---|---|---|---|---|---|
| 24×80 | wireframe, mono | **30.00 fps** | 44 µs | 0.1% | 10.00 s | +0 |
| 24×80 | solid, mono | **30.00 fps** | 45 µs | 0.1% | 10.00 s | +0 |
| 24×80 | solid, green | **29.99 fps** | 81 µs | 0.2% | 10.00 s | +0 |
| 40×120 | solid, mono | **29.99 fps** | 104 µs | 0.3% | 10.00 s | +0 |
| 60×200 | solid, mono | **29.99 fps** | 209 µs | 0.6% | 10.00 s | +0 |
| 60×200 | solid, green | **29.99 fps** | 608 µs | 1.8% | 10.00 s | +0 |
| 128×256 (the maximum) | wireframe, mono | **29.99 fps** | 445 µs | 1.3% | 10.00 s | +0 |
| 128×256 (the maximum) | solid, mono | **29.99 fps** | 1095 µs | 3.3% | 10.00 s | +0 |
| 128×256 (the maximum) | solid, **green** | **29.94 fps** | 10 764 µs | **32%** | 10.03 s | +0 |

Every row is `--frames 300 --stats` under a real pty of that size, so the
pacing, the drawing and the `write(2)` stream are all inside the measurement.
A 30 fps frame is 33333 µs; the most expensive geometry tested uses a third
of it.

**The last row is the interesting one, and it is not the geometry.** Solid
`mono` at 128×256 costs 1095 µs a frame; the same frame in truecolor costs
10 764 µs — 10× more — and it is all SGR. `fb.emit_sgr` assembles its 36
bytes one `emit_byte` call each, and `mono` emits `ESC[0;39;49m` for *every*
cell because all of `mono`'s colours are the same `fb.DEFAULT`, so the
`cur_fg`/`cur_bg` tracker suppresses it after the first. Truecolor gives each
cell a distinct colour, so most of the ~2000 changed cells in a frame get a
fresh 36-byte triple: 59 KB of ANSI a frame, 1.8 MB/s at 30 fps. That is
where the head room goes and it would be the first thing to run out on a
bigger surface.

Unpaced, `--frames 3000 --no-tty --stats` reports **17 µs** (wireframe) and
**21 µs** (solid) of work a frame. `--fps 0` in the terminal path, with no
pacer at all, renders 60 frames at 24×80 in 3 ms — **16 849 fps**.

**Heap.** `heap_used()` across the frame loop:

| run | frames | delta |
|---|---|---|
| `--no-tty` wireframe | 3000 | **+0 bytes** |
| `--no-tty` solid | 3000 | **+0 bytes** |
| interactive, 24×80 / 40×120 / 60×200 / 128×256, mono and green | 300 each | **+0 bytes** |
| interactive, 24×80 | 100, 300, 900 | **+0 bytes** |
| interactive, **with a mid-run resize** | 300 | **+0 bytes** |

The only allocation the program makes is the one `fb.Surface` (1.5 MiB) from
`fb.new`, before the loop.

## Frozen toolkit

Vendored copies, **byte-identical to `examples/_toolkit/`**, unedited:

| file | sha256 (first 16) | lines | what |
|---|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 | integer Q30 `sin cos tan sqrt atan2 …` |

The toolkit revision frozen here is **`examples/_toolkit/` as of
2026-10-04**, those five files and nothing else. This folder's copies are
unedited: `diff` against `_toolkit/` is empty for all five. The one place
this example needed something the toolkit does not offer — a window size
without a per-call allocation — is a **separate def**, not an edit:
`poll_size()` in `cube.y` does the same ioctl into its own buffer.

Two toolkit conventions this example follows and does not re-derive:
`syscall` arguments are in **kernel register order**, so `ioctl(fd, request,
arg)` is `syscall(16, fd, REQUEST, arg)`; and inside `struct termios`,
**VTIME is byte 22 and VMIN is byte 23**. Neither is ever at risk here
because `tui` does all the termios work — `poll_size()` only needs the
argument *order* and `TIOCGWINSZ`'s value, both of which `tui` exports.

## Files

| | |
|---|---|
| `cube.y` | the whole program: CLI, geometry, projection, both draw modes, both output paths, and the two self-tests |
| `EXPECTED` | exact stdout of `./cube --frames 60 --no-tty` — 1500 lines, 91 080 bytes |
| `cube_pty_check.py` | the pty harness: window size, keys, resize, `SIGKILL` |
| `golden/wire.txt`, `golden/solid.txt`, `golden/floor.txt` | captured frames, so the cube is visible without running it |
| `golden/README.md` | how those were captured, which frames were kept and why, and what to look at |
| `fx.y` | `4b47a9bfef0c1e30` | 694 | |

`gate.conf` in this folder is the orchestrator's, not this example's.

Line counts: `cube.y` 1238, `cube_pty_check.py` 180, `golden/README.md` 82.

The built binary is **not** committed — the build line above is the whole
recipe, and `cmp` on a rebuilt copy is one of the acceptance checks anyway.
`./gate.py cube` from `examples/` is 8/8.

## A reader's five minutes

1. `head -60 EXPECTED` — a quarter of the deterministic run, and it is a cube
   turning, as text.
2. `./cube --selftest 60` — T1 and T2, exit 0. This is the part of the
   example that would have caught its own two defects.
3. `grep -n 'THE DIVIDE GUARD' -A 12 cube.y` — the one place that keeps a
   division-by-zero trap out of the middle of a frame.
4. `grep -n 'def seg' -A 34 cube.y` — the diagonal-edge bug and its fix, in
   one function, with the reason in the comment.
5. Run it for real: `./cube --solid --color=amber --floor`, press `s`, then
   `c`, then resize the window mid-turn. The resize is the interesting one:
   the grid and the cube both re-derive from the new geometry on the next
   frame, with no allocation.
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
