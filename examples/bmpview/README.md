# bmpview — a BMP image viewer for the terminal

Decodes a real Windows BMP into one reusable RGB buffer and paints it with
terminal cells, three ways. Ships its own picture (generated, committed,
`embed`ed), refuses twenty kinds of malformed file with a message that names
the problem, and lets you scroll and zoom the result.

```
build:  ../../refs/ycc.ref bmpview.y -o bmpview
run:    ./bmpview                            interactive, until q
        ./bmpview --frames 2 --no-tty          the deterministic run
        ./bmpview --file photo.bmp            any BMP on disk
        ./bmpview --selftest                  the decoder's own tests
```

Nothing else is needed beside the folder: no image is downloaded, the toolkit
is vendored, and the test image is committed. Built and checked against
`refs/ycc.ref` sha256 **c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631**.

---

## What to look at

| file | what |
|---|---|
| `bmpview.y` | the CLI, the view transform, the three renderers, the interactive loop |
| `bmp.y` | the decoder: header parse, the row stride, the palette, and every guard |
| `selftest.y` | 55 assertions: 5 files accepted, 20 refused, 29 pixels checked |
| `gen_image.py` | writes `data/*.bmp` and `golden/probes.txt`. Deterministic. |
| `verify_render.py` | re-renders the text dump from an independent Python BMP parse |
| `pty_check.py` | drives the interactive path through a real pty |
| `EXPECTED` | the exact stdout of the `run=` line in `gate.conf` |
| `golden/` | the picture as text, in every mode, plus `probes.txt` |

Three things are worth reading before the code:

1. **`bmp.y`, the stride.** `stride = ((w * bpp + 31) / 32) * 4`. Every row
   starts on a four-byte boundary, and `data/tux.bmp` is **63 pixels wide on
   purpose**: 63 × 3 = 189 bytes per row, padded to 192. A decoder that
   forgets the padding shears every row below the first, and this image cannot
   pass one.
2. **`bmpview.y`, `sample()`.** One box filter in integers, used by the
   renderer, the text dump and the `--no-tty` summary alike. The lines where
   red and blue are accumulated carry a comment about the order, because
   getting it wrong renders every picture with the channels swapped — which is
   almost invisible on a grey gradient and obvious on the first coloured shape.
   It happened here, and `verify_render.py` is what caught it.
3. **`bmpview.y`, `sline()`.** The status line writes digits straight into the
   framebuffer instead of calling `tostring()`, because a string built on the
   frame loop is a leak (see *No per-frame allocation*).

---

## The BMP format, as implemented

All fields little-endian. Offsets are absolute file offsets.

**File header, 14 bytes**

| off | size | field | what this decoder does |
|---|---|---|---|
| 0 | 2 | `bfType` | must be `'B' 'M'` (reads as 0x4d42) |
| 2 | 4 | `bfSize` | the file's own length; **cross-checked** against reality |
| 6 | 2+2 | `bfReserved1/2` | ignored |
| 10 | 4 | `bfOffBits` | where the rows start; 0 means "compute it" |

**DIB header, at offset 14, `biSize` bytes long**

| off | size | field | what this decoder does |
|---|---|---|---|
| 14 | 4 | `biSize` | 40 (BITMAPINFOHEADER), 108 (V4) or 124 (V5) accepted; 12 (OS/2) and 52/56/64 refused by name |
| 18 | 4 | `biWidth` | **signed**; must be > 0 |
| 22 | 4 | `biHeight` | **signed**; 0 refused; **negative means top-down rows** |
| 26 | 2 | `biPlanes` | must be 1 |
| 28 | 2 | `biBitCount` | 8, 24 or 32 |
| 30 | 4 | `biCompression` | 0 = BI_RGB only; every other code is named in the diagnostic |
| 34 | 4 | `biSizeImage` | advisory; not trusted |
| 38 | 8 | `biXPelsPerMeter`, `biYPelsPerMeter` | ignored |
| 46 | 4 | `biClrUsed` | palette entries; 0 or > 256 means 256 |
| 50 | 4 | `biClrImportant` | ignored |

Only the first 40 bytes of a V4/V5 header are read, which is why those two are
accepted at all: the fields this viewer needs all live in the first 40.

**Palette, 8-bit images only.** Four bytes per entry, BGRA, immediately after
the DIB header. `biClrUsed` entries, or 256 when it is 0 or out of range.
Everything between the end of the DIB header and `bfOffBits` *is* palette, so
that — not `biClrUsed` alone — is the bound an index is checked against; see
*the 4-entry palette* below.

**Pixel rows.** `biHeight` rows, each

```
stride = ((width * bits_per_pixel + 31) / 32) * 4
```

| shipped file | size | bpp | bytes/row | stride | padding |
|---|---|---|---|---|---|
| `data/tux.bmp` | 63 × 47 | 24 | 189 | **192** | **3 bytes** |
| `data/topdown.bmp` | 63 × 47 | 24 | 189 | **192** | **3 bytes** |
| `data/bgra32.bmp` | 63 × 47 | 32 | 252 | 252 | 0 |
| `data/blocks8.bmp` | 61 × 45 | 8 | 61 | **64** | **3 bytes** |

The pad bytes are `0xAA`, so `xxd` on the file shows the stride directly.

**Row order.** A positive `biHeight` is bottom-up: the first row in the file is
the *bottom* row of the picture. A negative one is top-down. `topdown.bmp` is
`tux.bmp` with `biHeight = -47` and the rows written the other way round, and
the self-test requires both to decode to **the same FNV checksum** — which is
the only assertion that catches a decoder that takes `abs(height)` and gets
away with it.

**Not supported, each with its own message:** OS/2 `BITMAPCOREHEADER`,
V2/V3 headers with channel masks, `BI_RLE8`, `BI_RLE4`, `BI_BITFIELDS`,
`BI_JPEG`, `BI_PNG`, 1/4/16-bit images, images above 1024 × 1024, and
multi-plane images. Alpha in a 32-bit image is ignored (`BGRX`), which is what
`BI_RGB` 32-bit actually stores.

---

## The display modes

| mode | one cell shows | colours | use it for |
|---|---|---|---|
| `half` (default) | **two image rows**, via `▀` U+2580 | 24-bit truecolour | looking at pictures |
| `colour` | one image pixel | 24-bit truecolour | seeing more of a large image, or a corner |
| `mono` | one image pixel | the terminal's own, glyph from a 10-level ramp | terminals without truecolour, and pipes |

**Why half blocks.** The upper half block paints its *foreground* over the top
half of the cell and leaves the *background* below. So one `fb.put` with the
upper image row as `fg` and the lower one as `bg` puts **two vertically
adjacent, independently coloured pixels** into one cell — full truecolour, not
a 4-level approximation. And a terminal cell is about twice as tall as it is
wide, so two image rows to a cell is exactly the correction that makes an
image pixel come out square instead of stretched. `colour` mode, one pixel per
cell, therefore renders the same picture 2:1 too tall; that is deliberate (it
buys twice the picture per cell row) and it is why `half` is the default.

`--no-tty` prints the picture as text instead, one character per cell, through
`fb.shade_ascii`. That ramp is ordered by **coverage, not brightness** — `' '`
to `'@'` — so the picture reads the same on a light and a dark terminal. The
character for a cell is the luminance of **all** the image rows in that cell,
averaged: the text grid has one line per cell row, so it cannot show what the
half block shows, and it says so rather than pretending otherwise.

---

## The view: a rational scale, not a scale factor

There is no `float` → `long` in Y and no math functions at all
(ORCHESTRATOR.md §2.4), so the zoom is two integers, `NUM/DEN`:

```
source rows of cell row i  =  [ origin + i*rpc*NUM/DEN , origin + (i+1)*rpc*NUM/DEN )
```

where `rpc` is 2 in half mode and 1 otherwise. Both ends come from the same two
integers, so the ranges **tile exactly** — no gap, no drift, no float, and no
accumulated error over a thousand rows. A span that collapses to 0 under
magnification is clamped to 1, which *is* the "replicate the pixel" rule.

| setting | NUM/DEN | meaning |
|---|---|---|
| fit (default) | `min(cols*1000/w, rows*rpc*1000/h)` / 1000 | the whole picture in the window, never magnifying past 1:1 |
| `--zoom 1` | 1/1 | one image pixel per cell (or two rows per cell in half mode) |
| `--zoom z` | 1/z | magnified z times, floor division |

Downscaling takes a box average of the whole `span × span` block in integers —
at zoom 1 the span is 1 and the sampler degenerates to one read per channel,
so there is no cost on the common path. Off the picture, `sample()` returns a
near-black slate, which is how the picture's edge is marked rather than
guessed at.

---

## Malformed input

Everything below goes through the **same** `bmp.load` the viewer uses; there is
no separate validation path that could disagree with the real one. Verified by
`./bmpview --selftest` (55 checks) and, through the CLI, on real files:

| case | message | exit |
|---|---|---|
| empty file (0 bytes) | `the file is 0 bytes, too short to hold a BMP signature` | 1 |
| 10 bytes | `truncated: the BMP file header is 14 bytes but the file is 10` | 1 |
| not a BMP (`PK…`) | `not a BMP: the file starts 4b50, not 4d42 ('BM')` | 1 |
| `bfSize` 4 MiB, file 9078 B | `the header says the file is 4194304 bytes but only 9078 are here; it is truncated` | 1 |
| `bfOffBits` = 16 MiB | `bfOffBits is 16777215, which is outside the 9078-byte file` | 1 |
| DIB header cut short | `truncated: the DIB header declares 40 bytes but only 26 are present` | 1 |
| OS/2 core header (12 B) | `OS/2 BITMAPCOREHEADER (12 bytes) is not supported; this viewer reads BITMAPINFOHEADER and later` | 1 |
| V3 header (56 B) | `BITMAPV3INFOHEADER is not supported; this viewer reads BITMAPINFOHEADER, V4 and V5` | 1 |
| DIB header size 999 | `unsupported DIB header size 999 bytes (this viewer reads 40, 108 and 124)` | 1 |
| width 0 | `the width must be positive; the header says 0` | 1 |
| height 0 | `the height must not be zero` | 1 |
| height −100000 | `the picture is 63x100000 pixels, which is past this viewer's 1024x1024 ceiling` | 1 |
| width 100000 | `the picture is 100000x47 pixels, which is past this viewer's 1024x1024 ceiling` | 1 |
| width 2147483647 | `the picture is 2147483647x47 pixels, which is past this viewer's 1024x1024 ceiling` | 1 |
| 7 bits per pixel | `unsupported bit depth 7; this viewer reads 8 (paletted), 24 and 32 bits per pixel` | 1 |
| 16 bits per pixel | `unsupported bit depth 16; this viewer reads 8 (paletted), 24 and 32 bits per pixel` | 1 |
| `BI_RLE8` | `compressed BMP: BI_RLE8 is not supported; this viewer reads uncompressed BI_RGB` | 1 |
| `BI_BITFIELDS` | `compressed BMP: BI_BITFIELDS is not supported; this viewer reads uncompressed BI_RGB` | 1 |
| 2 colour planes | `the header declares 2 colour planes; a BMP has exactly one` | 1 |
| pixel rows missing | `truncated: 47 rows of 192 bytes need 9024 bytes from offset 54, but only 3946 are present` | 1 |
| 8-bit, palette missing | `truncated: 256 palette entries need 1024 bytes at offset 54, but the file is only 200 bytes` | 1 |
| missing file | `cannot read /no/such.bmp: no such file, or it is a directory` | 1 |
| a directory | the same message — `fs.read_bytes` answers `none` for one | 1 |
| `--file` with no value | `option '--file' needs a value` | 2 |
| unknown `--option` | `unknown option '--bogus'` | 2 |
| `--mode nosuch` | `--mode must be half, colour or mono, not 'nosuch'` | 1 |
| `--zoom 99` | `--zoom must be 0 (fit) to 16` | 1 |
| `--size 2x2` | `--size must be 8x3 to 256x128 cells` | 1 |
| no tty and no `--no-tty` | `not a terminal; use --no-tty` | 1 |

**A negative height is not malformed.** It is the top-down row order, and
`data/topdown.bmp` is accepted, decoded and checksumed against `tux.bmp`. The
malformed negative-height case is a height whose *magnitude* will not fit the
buffer, and that is the row above: the ceiling test divides instead of
multiplying (`w > PIXCAP / hh`) precisely so that two hostile 32-bit header
fields cannot overflow into a small product.

**The 4-entry palette.** A paletted file that declares four palette entries,
writes four, and then has pixels indexing up to fifteen is structurally sound,
so it is **accepted** — and every out-of-range index is caught one pixel at a
time, painted black, and counted. `bmpview` prints
`palette 4 entries at offset 54, 2489 of 2745 pixels indexed outside it and
painted black`. A corrupt index costs one black pixel and a number, not the
whole picture; a validation pass over the whole file would cost a second read
of it to catch the same thing.

---

## No per-frame allocation

The heap is an arena and nothing is ever freed (ORCHESTRATOR.md §2.7), and an
array literal written in a loop costs **72 bytes every time the expression
runs** (measured) — so a literal in the per-cell loop would leak by the
megabyte per frame. Hence:

* the pixel buffer is **one module-level fixed array**, `[byte; 3145728]` in
  `bmp.y`, written by index and never grown. The price is a 1024 × 1024
  ceiling, which is a diagnostic rather than an allocation;
* the framebuffer's surface and its output buffer are allocated once;
* the status line writes digits into the surface (`sline`), and the scratch
  array it uses is module-level, because a local `[long; 12]` literal is 72
  bytes *per frame*;
* the text dump goes out through a fixed `[byte; 300]` and one `write(2)`;
* the view is two longs.

Measured, `--time` on stderr:

```
$ ./bmpview --frames 200 --no-tty --time --quiet
bmpview: decode 15 us, 200 frames in 15 ms (75 us a frame), heap 5002312 -> 5002312 (delta 0)
```

**Heap delta 0 over 200 frames**, in all three modes, at `--zoom 0`, `1` and `4`,
and **delta 0 over 121 interactive frames** driven through a pty with 120
keystrokes mixing scrolls, zooms and mode changes:

```
bmpview: 121 frames in 4110 ms, heap 5001968 -> 5001968 (delta 0)
```

The first frame repaints the screen and every later one emits nothing: that is
`fb.flush_diff` doing per-row diffing against a settled screen, and it is why
the byte total in the summary does not grow with the frame count.

Two limits worth stating. The pixel buffer is a **fixed 1024 × 1024** (3 MiB),
so a larger picture is refused with a diagnostic rather than decoded — the
alternative would be growing the store, and growing it on the arena is a leak.
And the framebuffer's capture buffer is 256 KiB, so `--no-tty` on a very large
surface whose every cell is a different colour would checksum a *truncated*
stream; the default 80 × 24 needs 45 KB of it, and `--no-tty`'s text dump does
not use the capture at all.

---

## Correctness: how the pixels were checked

Three independent layers, because a spot check of single pixels cannot see a
wrong stride or a wrong row order.

**1. Known pixels, against the generator.** `gen_image.py` *defines* the picture
(a two-axis gradient, a white disc with a red ring, two checkerboards, a
one-pixel frame — no randomness anywhere) and writes `golden/probes.txt`: 29
`(file, x, y, r, g, b)` rows. `--selftest` decodes the file and compares the
pixel at each coordinate. The table inside `selftest.y` was generated from
`golden/probes.txt`, so the two must agree:

```
$ ./bmpview --selftest | grep '^probe' | cut -d' ' -f2-7 | diff - golden/probes.txt
$ echo $?
0
```

`topdown.bmp` and `bgra32.bmp` appear in that table with **the same
coordinates and the same colours** as `tux.bmp`: top-down row order and a BGRA
quad are supposed to be transparent to the picture, and these rows are what
prove it. The probes at `y > 0` are the interesting ones — a decoder that
ignores the row padding gets them wrong.

**2. One picture, three containers.** All three files holding the same 63 × 47
picture decode to FNV-1a64 `-6975835646883560411`:

```
  ok    bottom-up, top-down and 32-bit all decode to fnv -6975835646883560411
```

**3. The whole chain, against a second implementation.** `verify_render.py`
parses the BMP again from scratch, in Python, and runs it through the same view
transform, box filter, integer luma and ASCII ramp, then diffs the result
against `bmpview`'s own text dump — row by row, byte for byte:

```
$ ./verify_render.py --all
ok   data/tux.bmp 80x23 zoom=0: 23 rows identical
ok   data/tux.bmp 80x23 zoom=1: 23 rows identical
ok   data/tux.bmp 80x23 zoom=3: 23 rows identical
ok   data/tux.bmp 120x45 zoom=0: 45 rows identical
ok   data/tux.bmp 100x40 zoom=2: 40 rows identical
ok   data/topdown.bmp 80x23 zoom=0: 23 rows identical
ok   data/bgra32.bmp 80x23 zoom=0: 23 rows identical
ok   data/tux.bmp 80x23 zoom=0 mode=colour: 23 rows identical
ok   data/tux.bmp 80x23 zoom=0 mode=mono: 23 rows identical

all renders agree
```

This is the check that earns its keep: it is what caught the red/blue swap in
`sample()` and an inverted `--size` (which parsed `80x24` as 80 *rows*).

---

## Regenerating the asset

```
$ ./gen_image.py
  tux.bmp          9078 bytes  42 4d 76 23 00 00 00 00 00 00 36 00 00 00
  topdown.bmp      9078 bytes  42 4d 76 23 00 00 00 00 00 00 36 00 00 00
  bgra32.bmp      11966 bytes  42 4d be 2e 00 00 00 00 00 00 7a 00 00 00
  blocks8.bmp      3958 bytes  42 4d 76 13 00 00 00 00 00 00 36 04 00 00
  golden/probes.txt 29 probes
```

`data/tux.bmp` is embedded by name in `bmpview.y`:

```
embed IMG_TUX from "data/tux.bmp";
```

which is why the folder is self-contained: the binary needs nothing at run
time. If you change the pixel function, re-run `gen_image.py` **and**
regenerate the `PROBES` table in `selftest.y` from `golden/probes.txt` — the
diff above is what catches the drift if you forget.

---

## The interactive path

`tui` owns the restore guarantee, so this example uses its shape and nothing
of its own: `raw_mode()`, `enter_screen()`, `arm_watchdog()`, one loop, and a
single `restore_all_exit(0)` at the end. There is no animation, so the loop is
draw → read one key → act: redraw-on-keypress is the whole event loop.

Keys: arrows or `hjkl` scroll, `+` / `-` zoom (2, 4, 8, 16), `f` and `0` fit,
`1` native, `g` cycles the mode, `q` or Escape quits. The status line shows the
file, the size, the mode, the zoom, the origin and the key hints — all of it
written into the framebuffer, allocation-free.

`pty_check.py` drives it through a real pty (tmux is not installed here):

```python
import fcntl, os, pty, select, struct, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.execv("./bmpview", ["./bmpview"]); os._exit(127)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
out = b""
for key in [b"+", b"\x1b[B", b"\x1b[C", b"-", b"g", b"q"]:
    os.write(fd, key); time.sleep(0.4)
    while select.select([fd], [], [], 0.05)[0]:
        out += os.read(fd, 65536)
print(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
```

`./pty_check.py ./bmpview` runs the full version:

```
first paint              : 45607B
alt screen entered/left  : True / True
cursor hidden / shown    : True / True
truecolour SGR triples   : 4781
U+2580 half blocks       : 9046
effect of each key       :
    zoom in +                  26284 B
    down ESC[B                 23924 B
    down ESC[B                 22935 B
    right ESC[C                24564 B
    zoom out -                 44815 B
    cycle mode g               26298 B
    quit q                        14 B
c_lflag before / after   : 0x8a3b / 0x8a3b
cooked mode restored     : True
exit status              : 0
RESULT                   : PASS
```

---

## Compiler notes

`refs/ycc.ref` sha256 `c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`,
recorded at build time and re-checked at the end of the task. Compiles with
**zero warnings**. There is no `make` target and no `src/` change: this is a
consumer of the compiler.

**The frozen toolkit.** Vendored from `examples/_toolkit/`, unmodified:

| file | sha256 (prefix) | lines |
|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 687 |

`fx.y` is vendored because the folder contract names it; nothing here calls it
(this example has no trigonometry — the view is integer arithmetic), and
`import fx;` is not present. The other four are used directly: `fb` for the
surface, `term` for raw mode and the alt screen, `args` for the command line,
`time` for the `--time` report.

### `str + byte` — worked around with `chr`

Filed in [`../BUGS.md`](../BUGS.md), *"`str + byte` segfaults"*. `s[i]` yields a
`byte`, and `str + byte` passes that numeric value to the string-concat helper
as if it were a pointer:

```y
print("x" + "abc")[0];   // SIGSEGV, exit 139
```

The filing lists two workarounds, `line += RAMP[i]` and
`line = line + chr(RAMP[i])`. **Against this pin only the second one compiles**:
`str += byte` is now rejected by the checker (`error: '+=' string: expected
str, got byte`), so the `+=` form in the filing's "Verified matrix" is out of
date — see the appended entry in `../BUGS.md`.

`bmpview` avoids the question entirely rather than choosing: the text dump
writes characters into a fixed `[byte; 300]` and leaves through one
`write(2)`, which allocates nothing and cannot hit the bug. Where a character
does have to become a string, `chr()` is used. The same reasoning is why the
status line writes digits into the surface instead of concatenating strings.

### Other things the language forced

* **No `break`, no `continue`** (§2.9). The header parse uses an early
  `return im;` per guard — seven of them, each carrying the message that names
  the failure — which is the direct alternative to a guard flag and reads
  better. The per-row and per-cell loops have nothing to break out of; the two
  that would have wanted it (the palette lookup, and the row loop's own bounds)
  are written as "compute the bound first, then index inside it" rather than as
  a loop with an escape.
* **No `float` → `long`, no math functions** (§2.4). The view scale is a
  rational pair of integers; the box filter and the luma are integer; zoom is
  an integer magnification.
* **Array literals leak.** 72 bytes each, per evaluation, so not one appears
  inside `draw()`, `sample()`, `sline()`, the decode loop or the text dump.
* **Fixed `[T; N]` ≠ `[T]`.** The pixel buffer is a fixed `[byte; 3145728]`, so
  the `Image` record's field is declared with that fixed type — a nested
  `[byte]` cannot hold it.
* **Arrays are references.** Every self-test fixture is a *copy*
  (`src[0:len(src)]`); `let bad = tux; set32(bad, ...)` would corrupt the
  embedded image and every case after it. `struct.u32le` / `u16le` write the
  fixtures, and `struct.get_u32le` / `get_i32le` read the header, both through
  bounds-checked wrappers in `bmp.y` — the std's readers do not bounds-check,
  so an offset past the end would trip the index trap.
* **`struct.get_u32le` is free, `struct.u32le` is not.** The getters cost zero
  bytes inside a loop, which is why the header parse can read field by field
  without thinking about it. The writers answer a *new* array (48 bytes a
  call), and an array slice is a *copy* (56 bytes for sixteen), so building a
  header means a four-store copy loop — filed in
  [`../SUGGESTIONS.md`](../SUGGESTIONS.md) as §9, with the measurements.
* **The header reads are `u16`/`u32`/`i32` field by field**, each guarded,
  rather than one `struct.unpack`. That is what lets a truncated file be
  diagnosed by name ("the DIB header declares 40 bytes but only 26 are
  present") instead of being a single "bad header".
* **`'q'` is not a character literal** — `c'a'` is, and a bare apostrophe in a
  file can turn a diagnostic into a different one (filed in `../BUGS.md`). The
  key codes are written down once as `K_Q`, `K_PLUS`, … with their meanings.
* **`fb.set_fd`** redirects the framebuffer to `/dev/null` in `--no-tty`, and
  `fb.capture_*` keeps the stream, so the summary can checksum the exact ANSI
  that was produced without putting escape sequences into `EXPECTED`.

### Filed findings

* [`../BUGS.md`](../BUGS.md) — `str + byte` segfaults (pre-existing). The
  entry's own follow-up, *"`str + byte` filing's `+=` workaround is now a
  compile error"*, records that the `+=` half of its matrix no longer compiles
  against this pin; filed in parallel with this example. Neither is duplicated
  here.
* [`../SUGGESTIONS.md`](../SUGGESTIONS.md) §9 — *no way to write one scalar
  into a `[byte]` at an offset*. Found here: `struct`'s getters cost zero and
  its writers cost 48 bytes a call, so building a BMP header in Y needs a
  copy loop.
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
