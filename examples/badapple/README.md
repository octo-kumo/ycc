# Bad Apple!! in the terminal — three Y players, one shared renderer

Three entry files, one pixel → text renderer:

| entry file          | cells  | video data | what |
|---------------------|--------|------------|------|
| `badapple.y`        | 160×60 | `s40x30`   | the original player's pipeline (40×30 mask, 16× bilinear upsample to 640×480), plain white on black |
| `badapple160x60.y`  | 160×60 | `s40x30`   | the same picture in termblocks glyphs, with the color modes |
| `badapple80x30.y`   | 80×30  | `t80`      | the low-resolution version, following the C reference `bad_apple80x30.c` (20×15 mask, temporal dither, bilinear upsample to 320×240 with S-curve sharpen) |

The two termblocks players import the shared **pixel → text
renderer** `tbrender.y`: every 4×8 cell is drawn with the
Hamming-optimal termblocks (character, fg/bg-flip) pair over the
284-mask charset — exact block families, diagonals/triangles, full
braille, space — with the lexicographic (err, charset priority,
no-flip) tie-break and an early exit on zero error.  The renderer also
owns the color pipeline, the SGR/UTF-8 emission and the per-row dirty
diffing.  `badapple.y` stands alone: it is the C reference's own
rendering logic (exact-match glyph families, flip SGRs, braille
fallback) and takes no options, as the C reference takes none.

## Build & run

```bash
./ycc -o badapple badapple.y
./ycc -o badapple160x60 badapple160x60.y
./ycc -o badapple80x30 badapple80x30.y

./badapple                    # 160x60, white on black
./badapple160x60 --color=green # 160x60, phosphor green
./badapple80x30 --color=green  # 80x30, phosphor green
```

Keep `tbrender.y` and the video data files next to the sources when
building (prebuilt static x86-64 binaries are included; `ycc` is
included for rebuilding).  The 284-entry charset table is built from
the block/braille geometry inside `tbrender.y`, so there is no table
file to ship.  Requires a truecolor terminal; plays 6569 frames at 30
fps in the alt screen and restores it on exit.

## Render options (the two termblocks players)

```text
--color=mono   classic white-on-black with flip SGRs (default)
--color=gray   per-cell least-squares truecolor grays (soft edges)
--color=green  the same fit on a phosphor green tint
--color=amber  the same fit on an amber tint
--color=ice    the same fit on an icy blue tint
--help         usage
```

Bare names (`./badapple160x60 gray`) work too.  Unknown `--` options
are rejected with the usage text.  `badapple.y` takes no options.

## The color fit (the "color stuff")

Adapted from the termblocks color pipeline: once the glyph for a cell
is chosen, the two cell colors are the least-squares fit of the soft
per-subpixel coverage `v` (0..64, straight from the player's bilinear
stage) over the DISPLAYED ink set.  Because the mask is binary, the 2×2
system decouples into two means:

    fg_byte = mean(v over ink subpixels)        * 255/64
    bg_byte = mean(v over background subpixels) * 255/64

A flip swaps the two sets — which is why the fitted modes need no flip
SGR: the colors carry the polarity.  Bytes are quantized to 8 levels to
cut SGR churn (an SGR is emitted only when the quantized fg/bg pair
changes within the row), then mapped onto the tint ramp.  Flat cells
become a space whose background carries the cell tone.  The low-res
player feeds the fit the S-curve-sharpened soft values (faithful to the
C reference); the 160×60 player uses the raw bilinear values.

## Files

| file | what |
|------|------|
| `badapple.y`           | entry 1 — 160×60 player, white on black (stands alone: the C reference's own glyph logic, no options) |
| `badapple160x60.y`     | entry 2 — the same picture in termblocks glyphs, with the color modes (imports `tbrender`) |
| `badapple80x30.y`      | entry 3 — 80×30 low-res player (imports `tbrender`) |
| `tbrender.y`           | shared pixel → text renderer: 284-mask matcher, color fit, SGR/UTF-8, row diffing; also where the charset is built |
| `gen_masks.y`          | writes the charset table out as 284 (mask u32, codepoint u32) pairs in termblocks priority order (`ycc -o gen_masks gen_masks.y && ./gen_masks`, or `./gen_masks PATH`).  The players build the same table from the same geometry in `tbrender.y`, so the two cannot drift; the file is not kept in the tree, and unlike the Python original this needs nothing but the compiler |
| `s40x30` / `t80`       | arithmetic-coded video for the two pipelines |
| `badapple`, `badapple160x60`, `badapple80x30` | prebuilt static binaries |

`ycc` (the Y compiler, two directories up or on `PATH`) builds all
three.  `compare80_t224.png` (a low-res frame: true 320×240 / C
reference logic as-displayed / termblocks) and `verification.txt` (the
end-to-end verification log) are kept with the release bundle rather
than in the tree.

## How the low-res player differs from the 160×60 one

The video side follows the C reference: a 480×360 source is
area-averaged + thresholded to a **20×15** mask, WNC-adaptively
arithmetic coded with one keyframe every 4 frames (`t80`), the
frames between keyframes are rebuilt by temporal dither (each changing
cell crosses at its own random phase), and the field is bilinearly
upsampled to **320×240** with an S-curve sharpen (`(v−32)·3+32`
clamped — the binary threshold is unchanged, the soft values gain
contrast for the color fit).  320×240 is exactly 80×30 cells of 4×8
square subpixels.  The 160×60 player keeps the original pipeline:
40×30 mask, 16× bilinear upsample to 640×480, no S-curve.

## Verification (see verification.txt)

* The `t80` format was pinned against the C reference itself: a
  scratch build of `bad_apple80x30.c -DDUMP` and the Python port dump
  **46/46 display fields byte-identically** (the stale "polarity bits"
  comment in the C is not part of the format).
* The full ANSI byte stream of each player (both modes per player:
  mono + one fitted mode) was modeled in Python — decoder, dither,
  upsample, matcher, color fit, SGRs, row diffing — and real pty
  captures of the compiled players are **byte-exact ordered
  subsequences** of the model (155/155 and 150/150 painted frames per
  run; dropped frames are the documented pace-skip behavior).
* The refactored 160×60 player's mono stream is **byte-identical** to
  the previously verified player (4.3 MB common prefix, 240 painted
  frames).
* Pacing: both players paint **360/360 frames in 12 s (30.0 fps)** to a
  file consumer, all four mode combinations.
* Accuracy (as-displayed, first 240 frames sampled): C reference glyph
  logic 99.80% mean / 99.47% min — its braille fallback emits a
  non-standard dot-bit order — termblocks **100.000% on every sampled
  frame**.
