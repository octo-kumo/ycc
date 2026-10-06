# x11 — an X11 client in Y, speaking the wire protocol over a raw socket

Y cannot link `libX11`, so this example writes the protocol itself: it opens
`/tmp/.X11-unix/X0`, performs the connection setup with the MIT-MAGIC-COOKIE-1
out of `$XAUTHORITY`, creates a pixmap, uploads the image with `PutImage`,
reads it back with `GetImage`, and **compares the FNV-1a digest of the pixels
the server returned against the digest of the buffer it rendered**. Not
"it drew something" — the same hash, over bytes that made a round trip through
a real X server.

That comparison is the point of the example. `./x11 demo` asserts a property of
a buffer in this program's own memory. `./x11 verify` asserts that the server
holds those same bytes. One without the other would prove only half of what a
reader assumes it proves, and **half of it is exactly what a plausible-looking
broken client would pass.**

## Build

```sh
../../refs/ycc.ref x11.y -o x11
```

Five files, zero warnings, no toolkit vendored (this example needs nothing from
`test/std/` — the fixed-point maths it wanted turned out to be unnecessary,
because an X11 protocol is integers throughout and there is not one float or
trigonometry in the whole handshake).

## Run

| command | what it does | needs a display? |
|---|---|---|
| `./x11 demo` | render in memory, print a digest, element counts and the channel sums | **no** |
| `./x11 demo --repeat N` | draw the scene N times; output is byte-identical for every N | **no** |
| `./x11 check` | the property battery — 115 assertions | **no** |
| `./x11 probe` | connect, handshake, and dump the server's setup reply field by field | yes |
| `./x11 verify` | the PutImage/GetImage round trip and the digest comparison | yes |
| `./x11 show` | open a real 320x240 window with the image | yes |
| `./x11 verify --no-display` | prove the degrading path, whatever `DISPLAY` says | **no** |

## What to look at

**Start with `check.y`'s group D and `scene.y`'s `disc_area_expect`.** They are
the two independent computations of one number. `gfx.disc` walks a (2r+1)² box
and tests `dx*dx + dy*dy <= r*r` on every pixel; `disc_area_expect` sums
`2*isqrt(r*r - dx*dx) + 1` over the columns, which is an exact statement about
integers derived from the definition rather than from the renderer. They agree
at 8497 for r=52. If you change one, the other will tell you.

**Then read the four comments in `xwire.y` that begin "THE FIRST DRAFT".**
Each marks a defect that compiled, ran, was accepted by a real X server, and
produced no error anywhere — and that only a comparison could catch. They are
worth reading because the failure mode is the lesson:

1. **`put_image_band` packed one row for a 64-row band.** It had a single loop
   over `x`, so 79360 of every 81920 bytes were whatever was already in the
   buffer. Compiled, ran, uploaded, server said nothing.
2. **The same function copied its own bytes.** It packed into `ob[0..]` and then
   copied to `ob[24..]` with `w8(ob[i])` — reading and writing one buffer at
   overlapping offsets, so the copy ate bytes it had just written. Now the
   pixels are packed *directly after* the header and nothing is copied.
3. **`scene_draw` was not idempotent.** `elem_add` appends, so a second call
   left ten entries in the scene table and the demo printed all ten. Found by
   `demo --repeat 25`, whose output is *required* to be byte-identical to
   `demo`'s and was not.
4. **`gfx.isqrt` halved its bit counter where the restoring method requires
   quartering**, and then ran one iteration past the end, halving the answer
   away. `isqrt(1)` returned 0. `disc_area_expect` sums `isqrt`, so the disc's
   predicted area came out 639 instead of 8497.

**Then `xwire.y`'s comment on which requests reply.** It is the single most
damaging thing to get wrong, and the design note this example started from had
it exactly backwards.

## The X11 protocol, as measured here

Everything below was established against the live server on this machine
(`xdpyinfo` reports X.Org 24.1.13 via Xwayland, one 3440x1440 screen) and is
what the code does.

**The server never speaks first.** A client that connects and waits to be
greeted hangs — an X server's first act is a *reply* to a connection-setup
request the client must send. This is worth stating loudly because I got it
wrong first: I connected, waited, saw a timeout, and recorded this display as
unavailable. It was available the whole time. `xdpyinfo :0` settles it in one
command.

**Only requests that return data produce a reply.** `CreatePixmap`,
`CreateGC`, `CreateWindow`, `MapWindow`, `PutImage` and `FreePixmap` are void:
answered by silence, or by an *asynchronous* error. Reading a reply after one
blocks until some later reply arrives and consumes that one, so every reply
from then on is off by one. `x_expect_silence()` does nothing, on purpose, with
a comment saying so.

**Three length traps, each of which produced `BadLength` (error code 16):**

- `CreatePixmap` is **16 bytes / 4 units**, because `width` and `height` are
  CARD16. Sending them as 4 bytes each makes a 20-byte request declared as 4
  units.
- `PutImage`'s header is **22 bytes and must be padded to 24** before the data.
  The declared length already counts those two bytes; omit them and the server
  reads two bytes into the next request.
- A request must be a multiple of 4 bytes.

**`$XAUTHORITY` length fields are big-endian.** A parser that assumes
little-endian — the natural assumption on x86 — reads the 18-byte name-length
field as `0x1200` = 4608 and walks off the end of a 92-byte file, with nothing
in the failure saying "endianness". So `read_cookie` does not parse: it
*scans* for the literal `"MIT-MAGIC-COOKIE-1"` and reads the one length field
that follows it. That is robust to the byte order because it does not care.

**Pixel order is BGRX, not RGBX.** The framebuffer holds `0x00RRGGBB` and the
server wants red *low*. Getting this backwards uploads a plausible-looking
image with red and blue swapped — and `verify` catches it, which is a large part
of why `verify` exists.

**One request cannot carry the image.** 320x240 at 32 bits is 307200 bytes
against a 262140-byte `maximum-request-length`, so `PutImage` and `GetImage`
both run in bands of 64 rows (81920 B each). `probe` prints the limit the
server reported rather than assuming it.

**Every read is a short read waiting to happen.** `read_exact` loops; a run
reports `short reads 6, short sends 0`. A short write is normal too and is
looped, not treated as an error.

**`$XAUTHORITY` and `$DISPLAY` come from `/proc/self/environ`.** There is no
`getenv` in this language. Reading the kernel's own block needs no allocation
beyond one fixed 64 KiB buffer, and it is the authoritative source rather than
a reconstruction.

## What the battery checks, and what it deliberately does not

115 assertions in about a second, with no reference file and no display. Every
expectation is one of:

- a **closed form** from the definition — a Bresenham line emits
  `max(|dx|,|dy|)+1` pixels because the major axis advances every step; a
  rectangle is `w*h`; a one-pixel frame is `2(w+h)-4`; a disc column at offset
  `dx` is `2*isqrt(r*r-dx*dx)+1`; a checkerboard lights the `(cx+cy)`-even cells,
  which is a closed form of the grid;
- a **constant computed outside this program** — `FNV_ZEROS`, the FNV-1a of
  230400 zero bytes, produced by a separate Python script, is
  `0x326e0739b4ae7325`. `check.y` asserts that a wiped framebuffer hashes to it
  and that the rendered scene does **not**. Without that, "the digest matches"
  would be satisfied by a buffer nobody drew into;
- a **figure counted back out of the finished image** by scanning pixels, which
  is not the number the drawing routine returned.

Group B measures the gradient *alone*, on a wiped buffer, and checks each
channel's total against a sum written out from the formula — including a
double loop over all 76800 pixels for blue. An earlier version of that check
asserted the same figure against the *finished scene* and was wrong by 5%,
because five elements are painted over the ramp. The renderer was right; the
test was wrong.

It never asks a drawing routine whether it drew correctly.

## Injected defects

Run `./inject-defects.py x11` from `examples/`. It applies each defect to a
fresh copy of this folder, rebuilds, and asks **three** detectors, because a
defect need not be visible to all of them:

- the **build** (gate item 1) — is there a new compiler warning?
- the **golden** (gate item 2) — does `demo`, and `demo --repeat 3`, still
  print EXPECTED byte for byte?
- the **battery** (gate item 8) — `check`, all 115 assertions.
- plus **`verify`**, when a display is present, because gate item 3 only probes
  the default run and so is blind to the entire wire-protocol path.

**Measured: 17 defects, 15 caught, 2 survived, 0 unjustified.** Both survivors
are proved equivalent rather than waved through, and the proofs are in the
harness next to the defect list so they cannot be quietly dropped.

| # | defect | caught by |
|---|---|---|
| 1 | `isqrt` halves the bit counter where the method requires quartering | D01, D02, D05 (predicted disc area 639 vs 8497) |
| 2 | `isqrt` runs one step past the end and halves the answer away | D01, D02, D05 (8 assertions) |
| 3 | Bresenham `dy` made positive | golden, C01, C02, C04 (12 assertions) |
| 4 | Bresenham tie test `e2 <= dx` → `e2 < dx` | golden, **H01, H02, H03** |
| 5 | `stroke_rect` draws the vertical runs in full, double-counting corners | golden, C07, C08 |
| 6 | `stroke_rect` draws a 1-row frame's only row twice | G10 |
| 7 | `disc` uses `<` instead of `<=` on the boundary | golden, D01, D05, D06 (9 assertions) |
| 8 | checkerboard cell origin off by one | **SURVIVED — provably a no-op, see below** |
| 9 | checkerboard pattern inverted (lit-cell *count* stays 185) | golden, H07, H08, H09 (7 assertions) |
| 10 | checkerboard row step off by one, last block overhangs | golden, C10, C11, E05 |
| 11 | gradient red divisor `w` not `w-1` | golden, B02, B03, B12 |
| 12 | gradient blue divisor `w+h` not `w+h-2` | golden, B02, B04, B06, B14 |
| 13 | disc radius clamped to `W_MAX` not `max(W,H)` | **SURVIVED — provably equivalent, see below** |
| 14 | an unused local | **the build warned** — nothing else could see it |
| 15 | `scene_draw` no longer clears the element table | **golden under `--repeat 3`** only |
| 16 | line colour made white (collides with the gradient's far corner) | golden, E04b |
| 17 | `PutImage` packs one row of a multi-row band | **`verify`: no MATCH** — only the display path sees this |

Four of those are worth dwelling on, because each was invisible to a detector I
had been relying on:

**#4 is why group H exists.** Changing Bresenham's tie test preserves the pixel
*count* (`max(|dx|,|dy|)+1`) and both *endpoints*, and only moves pixels in
between. All 102 original checks stayed green. 575 of the 3481 small slopes
differ under it — **including the scene's own 140x62 line** — so this was a
genuine blind spot in a battery that otherwise looked thorough. Group H checks
the pixel *set*, against `minor(i) = (i*min + max/2) / max`, which is the same
geometry computed a different way.

**#8 is a defect that could not fail.** `checker` steps `y` by `cs`, so `y` only
ever takes the values 0, cs, 2cs, … and for `y = 3k` the two forms agree
exactly: `(3k+1)/3 = k` under integer division, and `k/3 = k`. The mutation
cannot change the image for *any* input. It was injected believing it would
break something; the battery's silence was correct and my defect list was
wrong. It stays in the list precisely because "the battery missed it" and "it
could not have failed" are different facts, and the harness now distinguishes
them.

**#14 and #17 are why the harness has three detectors and a fourth.** A defect
whose only symptom is a compiler warning is invisible to a battery; and a defect
in the wire protocol is invisible to the battery *by design*, because `check`
must run on a machine with no display. #17 is the `PutImage` bug this example
was actually written to find, and `verify`'s digest comparison is the only thing
in the folder that can see it.

**#15 is why `demo --repeat` exists.** One draw appends five elements to an
empty table and looks perfectly correct; only the *second* draw diverges. The
golden comparison now runs `demo --repeat 3` against the same EXPECTED file,
which is a stronger check than it looks.

## Compiler workarounds

No compiler bug was found, so nothing is filed in `BUGS.md`. Every workaround is
in the code with a comment naming it:

- **no `getenv`** — `$DISPLAY` and `$XAUTHORITY` are read from
  `/proc/self/environ` (`xwire.env_get`);
- **no `[byte; N]` parameter unification** (`SUGGESTIONS.md` #12) — the request
  and reply buffers are module-level `[byte; 131072]`, which is also why nothing
  here allocates per pixel;
- **no cast syntax and no float→long** — the protocol is integers, so the only
  conversions are `>>`/`&` shifts;
- **no `break`/`continue`** — every loop's exit condition is spelled out in a
  comment above it, including the two that could run away (`disc` is bounded by
  `2r+1 ≤ 641`; `isqrt` by `bit /= 4` reaching 0 in ≤ 32 steps);
- **no out-parameters** — `gfx.st` is a module-level record the stat routines
  fill, since a helper assigning to a scalar parameter changes nothing;
- **indexing a `str` yields a `byte`**, not a one-character string, so `ord()` is
  the wrong tool (`ord(s[i])` is a type error) and `chr()` is the way back;
- **runtime traps print to stdout**, so every failure path is `eputs` plus a
  non-zero exit — which is also what keeps the golden diff clean;
- `def main()` is not auto-called, so the driver ends in `exit(main())`.

## Degrading

Every X path fails to a one-line diagnostic on **stderr** and a non-zero exit,
naming the step that failed. All six measured:

| condition | exit | stdout | stderr |
|---|---|---|---|
| `--no-display` | 3 | **0 B** | `x11: --no-display requested, so no X server is contacted` |
| `DISPLAY` unset | 1 | 0 B | `x11: DISPLAY: DISPLAY is not set` |
| `DISPLAY=notadisplay` | 1 | 0 B | `x11: DISPLAY: DISPLAY is 'notadisplay', expected ':N'` |
| `DISPLAY=:99` (no socket) | 1 | 0 B | `x11: connect: connect to /tmp/.X11-unix/X99 failed, errno 2` |
| `XAUTHORITY` unset | 1 | 0 B | `x11: XAUTHORITY: XAUTHORITY is not set` |
| `XAUTHORITY=/nonexistent/auth` | 1 | 0 B | `x11: XAUTHORITY: cannot open /nonexistent/auth (errno 2)` |

An X11 error reply is decoded rather than reported as "out of step": the code,
the sequence number, the bad value and **the name of the request the server
rejected**. That is what turned "the queue is out of step" into "CreatePixmap is
16 bytes, not 20", which is how the length bug was found in the first place.

## Notes

- The window is **320x240 on a 3440x1440 screen**, because the screen belongs to
  whoever is sitting at it. `show` holds the connection open for one second
  before closing it, because every resource a client creates is owned by its
  connection: closing it destroys the window. The first draft printed "it will
  stay up for about a second" and closed immediately, so it stayed up for no
  time at all.
- A socket receive timeout (3 s) is set with `setsockopt`, so a server that
  accepts and then says nothing cannot hang the program. That timeout is also
  how "a correctly formed `CreatePixmap` produces no reply at all" was
  established.
- Wayland is also live on this machine (`/run/user/1000/wayland-0` answers), and
  a Wayland client would need `SCM_RIGHTS` fd passing for the compositor to hand
  over a buffer. X11 was chosen because it is a plain byte stream over a Unix
  socket, and because it is confirmed working.

## The pinned compiler

```
31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755
```

`refs/ycc.ref`, sha256 above. No toolkit module is vendored into this folder,
so there is no vendored sha to record.

**The pin has moved twelve times during the campaign.** Each move is *appended*
below rather than written over, because a recorded sha is a claim about a
specific compiler and the history is evidence; the rule is that when the pin
moves, item 0 must be the **only** failing row before a single README is
touched, and every filing in `BUGS.md` is re-verified against the new compiler
because a symptom recorded against a compiler that no longer exists is not a
fact.

```
> pin history for this folder, oldest first:
>
> 625efd81...  the compiler this folder was first written against
> 1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3
> 31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755  current
>
> On move #12: item 0 was the only failing row, and all 11 BUGS.md filings
> re-verified under the new compiler. Nothing else in this folder changed --
> EXPECTED is byte-identical across the move, because the codegen this example
> depends on did not.
```

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
