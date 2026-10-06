# `life` — Conway's Game of Life in the terminal

A live view and a headless summary of Conway's automaton, on a torus-wrapped
grid, with RLE input and a population histogram. Written in Y, compiled by the
pinned `refs/ycc.ref`, with no floating point, no allocation in the generation
loop, and no runtime path that can trap.

```
$ ./life --pattern gosper --size 80x24 --frames 60
life -- Conway's Game of Life, rule B3/S23, torus edges

  pattern        : gosper
  grid           : 80 x 24 (torus)
  frames         : 60
  seed           : 1

summary
  initial live   : 36
  final live     : 54
  peak live      : 74
  populations    : 36 39 45 38 35 35 36 33 40 30 28 30 35 36 47 36 43 39 42 38 45 46 42
                   49 48 38 37 49 40 47 40 44 45 51 45 52 52 54 64 57 58 63 71 64 74 64 62
                   60 68 58 66 67 71 62 62 63 50 56 49 53 54 (61 generations, 0 to 60)
  histogram      : (live cells -> generations at that count)
                   28     live cells -> 1        generations
                   30     live cells -> 2        generations
                   ...
  frozen         : never -- still evolving at generation 60
  extinct        : never
```

---

## Build and run

```sh
YCC=/home/yun/Projects/compiler/refs/ycc.ref
(ulimit -S -v 3670016; $YCC life.y -o life) </dev/null
```

The five toolkit modules and `sim.y` / `rle.y` are imported by name from this
directory, so the folder builds on its own with nothing else present.

```sh
./life                                   # the live view (alt screen, 30 fps)
./life --frames 200                      # headless summary, exit 0
./life --pattern gosper --size 80x24 --dump 15   # print generations as text
./life --rle 'bo$2bo$3o!' --frames 12   # a pattern from RLE
./life --help
```

**The documented deterministic run** — `EXPECTED` is the exact stdout of

```sh
./life --pattern glider --size 40x18 --frames 12 --dump 4
```

```sh
./life --pattern glider --size 40x18 --frames 12 --dump 4 | cmp - EXPECTED && echo same
sh capture.sh && git diff --exit-code     # regenerating moves nothing
```

## Options

| flag | meaning |
|---|---|
| `-p, --pattern NAME` | `glider` (default), `gosper`, `lwss`, `blinker`, `block`, `random`, `empty` |
| `-z, --size WxH` | the grid; `80x` means square, the default is the terminal size minus its status line |
| `-s, --seed N` | the seed for `--pattern random`; same seed ⇒ byte-identical grid |
| `-d, --density N` | percent of cells alive in a random pattern (default 30) |
| `-r, --rle STR` | the pattern as RLE; overrides `--pattern`, says so on stderr |
| `-f, --frames N` | run exactly N generations, print the summary, exit 0 |
| `--dump N` | print the grid as `#`/`.` text at generations 0, N, 2N, … and at the last one |
| `--fps N` | the live view's frame cap (default 30, `0` = uncapped) |
| `-c, --color MODE` | `mono` (default), `gray`, `green` — the live view's colours |
| `-S, --stats` | elapsed time, rate, `heap_used()` before/after, trace coverage |

Exit codes: **0** ran (or `--help`), **1** every diagnostic — an unknown option,
a bad `--size`, an unknown pattern, an RLE string that does not parse, or no
terminal for the live view. Diagnostics go to stderr and never to stdout, which
is what lets `EXPECTED` be diffed (a runtime trap prints on *stdout* in Y and
would corrupt the diff; see `ORCHESTRATOR.md` §2.6).

### Keys (live view)

`q` `Esc` `Ctrl-C` quit · `space` pause · `.` one generation · `n` next pattern ·
`r` reseed random with `seed+1` · `c` cycle colour · `+` `-` speed · `h` the key
list.

---

## What to look at

- **`sim.y:step()`** — the whole example in one function: eight neighbour loads
  per cell, unrolled; `cur`/`nxt` swapped by three reference writes. Read the
  comment above it for why it is written that way.
- **`sim.y:new()`** — the torus, precomputed into four 512-entry tables
  (`px`/`nx`/`py`/`ny`). The wrap is defined once, with a non-negative operand
  before the `%`, instead of eight times per cell per generation.
- **`rle.y:parse()`** — a strict RLE reader that answers `{ ok, msg }` instead
  of exiting, so no input can take the terminal down with it. Every rejection
  has a message: empty string, no `!`, text after `!`, a bad run character, a
  run count over the grid, a cell outside the grid, an unsupported rule.
- **`life.y:run_headless()`** — the one loop, with the report built from fixed
  tables *after* the run, and `heap_used()` read either side of the loop.
- **`life.y:winsize()` and the `sb_*` helpers** — the two places where the
  obvious spelling allocates and the fixed-buffer one does not. Both carry the
  measurement that found them.
- **`life.y:run_live()`** — the tui lifecycle pattern: `raw_mode`,
  `enter_screen`, `arm_watchdog`, one `restore_all_exit` at the bottom that
  every exit routes through.
- **`golden/`** — generations as text: `glider.txt` (the documented run),
  `lwss.txt` (the spaceship's 4-generation cycle), `blinker.txt` (period 2),
  `gosper.txt` and `rle-glider-gun.txt` — the same 36-cell gun, entered as a
  built-in and through the RLE parser. They are not identical files, and should
  not be: RLE coordinates are absolute, so `--rle` puts the pattern at the
  origin, while a built-in is centred on the grid. Shift one by (22, 7) on
  80 × 24 and the cell sets are equal at every generation.
  `random-seed7.txt` is the seeded random grid.

Three patterns are worth checking against the literature, and all three do:

```sh
./life --pattern lwss   --size 26x9 --frames 4 --dump 4   # translates 2 left in 4 gens, 9 cells
./life --pattern blinker --size 20x10 --frames 4 --dump 1 # period 2, 3 cells forever
./life --pattern gosper  --size 80x24 --frames 300       # 36 live cells, cycles, grows ~5 per 30 gens
```

The gosper's population line is the gun's own fingerprint: `36 39 45 38 35 35
36 33 …`, then it climbs by about five cells every thirty generations as the
gliders it emits leave the grid behind.

---

## Measurements

**No per-generation allocation.** `heap_used()` is read after the header and
again the instant the generations finish, so the only thing between the two
readings is the loop:

```
$ ./life --pattern random --seed 7 --size 200x100 --frames 100000 --stats
  heap before    : 8747544 bytes
  heap after     : 8747544 bytes
  heap growth    : 0 bytes over 100000 generations
```

The grid is four fixed `[long; 262144]` arrays (8 MiB) allocated once in
`sim.new()`; a generation is computed into the scratch array and the two
references are swapped. 20 000 generations × 160 KiB would be 3 GiB if it copied.

**And none per *frame* either**, which took two bugs to find and is the more
interesting number:

```
$ python3 pty_smoke.py ./life --stats        # a 12 s session at 24x80
  heap growth    : 0 bytes over 361 generations
```

The live view's frame loop starts from nothing but fixed buffers: the grid is
swapped, not copied; the status line is assembled in a module-level
`[byte; 256]` and drawn cell by cell (`sb_*` below); and the window size is read
by `winsize()` into a module-level buffer. Both of the last two exist because
the first version allocated, and `--stats` is what said so. See
[Language notes](#language-notes-every-workaround-and-where-it-lives) 12 and 13.

**Throughput**, `random --seed 7 --frames 5000 --stats`, three runs each, on the
shared machine this was written on:

| grid | cells | generations/second | per generation |
|---|---|---|---|
| 80 × 24 | 1 920 | 47 600 – 62 900 | ~16 µs |
| 200 × 100 | 20 000 | 5 980 – 6 080 | ~166 µs |
| 512 × 512 | 262 144 | 396 – 433 | ~2.4 ms |

That is ~120 M cell-updates/second at 200 × 100, with bounds-checked indexing on
every one of the nine loads per cell. The 80 × 24 figures move by 30% between
runs — it is a 16 µs generation, so a scheduling hiccup is a large fraction of
it — while 200 × 100 and 512 × 512 repeat to within 2%.

**The live view holds 30 fps.** Through a pty at 24 × 80, the status line reads
`gen 91 | live 5 | running | mono | 30.00 fps/30 | seed 1 | glider | h keys`
after 3.0 s, and the whole 3 s of output is 6 925 bytes (a glider changes three
cells a generation, so `flush_diff` has almost nothing to redraw). The live view
needs 1 920 cells a frame and manages ~50 000 generations/second, so it has
~40× the headroom it uses; `--fps 0` runs it as fast as the terminal takes the
bytes.

**The interactive path, under a real pty.** `tmux` is not installed here, so
`pty_smoke.py` allocates one from Python — the same harness `tui` was
verified with. It checks five sessions: `q`, `Esc`, `Ctrl-C`, a mid-run
`TIOCSWINSZ`, and the remaining keys; each must exit 0, leave the alt screen,
show the cursor and put the termios back.

```sh
python3 pty_smoke.py ./life
```

```
1. 'q' quits
  ok   alt screen entered  [b'\x1b[?1049h\x1b[?25l\x1b[']
  ok   live cells drawn as full blocks
  ok   frames drawn  [2123 bytes in 1.2 s]
  ok   exit code 0  [0]
  ok   alt screen left
  ok   cursor shown again
  ok   raw mode was actually entered while running
  ok   termios restored on exit
2. Escape quits
  ok   exit code 0  [0]
  ...
5. the other keys (pause, step, pattern, colour, speed, help)
  ok   exit code 0  [0]
  ok   termios restored
all checks passed
```

The seven-line core of it, for the README of a reader who wants to see a live
run captured:

```python
import os, pty, select, struct, termios, fcntl, time
pid, fd = pty.fork()
if pid == 0:
    os.execv("./life", ["./life"]); os._exit(1)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
time.sleep(1.5)                      # let it draw
os.write(fd, b"q")                   # quit
os.waitpid(pid, 0)                   # -> 0, terminal restored
```

---

## The std units this uses

Vendored copies, byte-identical to `test/std/`, **not edited**:

| file | sha256 (first 16) | lines | used for |
|---|---|---|---|
| `fx.y` | `4b47a9bfef0c1e30` | 694 | *not imported* — see below |

`fx.y` is vendored because the frozen set is the frozen set, and this example
**does not import it**: Life is integers and booleans, so there is no trig, no
fixed point and no float anywhere in it. Nothing was changed in any of the five
copies — the diff against `test/std/` is empty.

**Compiler pin.** `refs/ycc.ref`, sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631` — the sha
in `refs/SHA256SUMS` when this folder was finished. It has moved twice during
this example's life (`d459af4f…` in `ORCHESTRATOR.md` §3/§8, then `63a4c3d0…`,
then this), and `EXPECTED` is byte-identical under all of them, which is worth
knowing: `refs/` keeps only the current binary, so an older pin cannot be
re-fetched to prove it. Pin this one. (The sha in `examples/SUGGESTIONS.md` §8,
filed from this folder, records the `63a4c3d0…` pin, which is the one this
example was written against.)

---

## Language notes: every workaround, and where it lives

Nothing here needed the compiler patched. Each of these is a shape the language
asked for, and the code says so where it applies.

1. **No character literals at all.** `k == 'q'` is a *lexer* error
   (`expected ')', got 'q'`). The live view compares `ord("q")` and friends.
   `tui`'s header comment shows the `k == 'q'` spelling, which does not
   compile against the pin. Not filed: the absence of a feature is a suggestion
   at most, and `TODO.md` §7 already covers literal syntax.
2. **`[v; n]` takes an integer literal only**, so a grid cannot be allocated at
   its own size: `[0; w * h]` is `error: expected an array size (an integer
   literal from 0 to 2147483647), got 'w'`. The grid is therefore four fixed
   `[long; 262144]` arrays with a logical `w`/`h`, which is also what the arena
   wants — allocated once, never resized — and `--size` above 512 × 512 (or
   262 144 cells) is a clean diagnostic instead of an 8 MiB guess. Filed as
   `examples/SUGGESTIONS.md` §8.
3. **No `break`, no `continue`.** The 3×3 neighbour sum in `sim.step` is
   *unrolled* rather than looped — a loop needs a `continue` to skip the centre
   cell, and the guarded-body idiom would cost eight extra branches per cell in
   the hottest loop in the program. The outer loop has no early exit at all: it
   runs exactly `h` rows, and every "are we done" decision lives in a guard flag
   in the caller (`run_live`'s `running`, the histogram's print/skip/print
   counter, `fill`'s `len(bad) == 0`).
4. **A `[T; N]` is not a `[T]`.** `populations(trace: [long], …)` will not take
   a `[long; 4096]`; the report helpers take the fixed types.
5. **No uninitialised typed binding.** `let sz: Size;` is
   `error: expected '=', got ';'`, so `--size` vs the terminal size is a
   block-expression binding: `let sz: Size = if (…) { … } else { … };`.
6. **A trailing `;` inside a block makes it void.** `def f() -> bool { x < y; }`
   is an error ("expected bool, got void") — the value is the last statement
   *without* the semicolon. Two one-line predicates in `rle.y` are written this
   way, and the way to spot the mistake is that the error names the return type.
7. **`exit()` is `void`,** so a `def … -> long` whose body ends in `exit(1)` is
   a type error. `die(msg) -> long` returns the exit code and the call site is
   `exit(die("…"))`, which cannot forget one half of the diagnostic.
8. **`s[i]` on a `str` is a `byte`,** so the bitmap test is `row[x] == 35`, not
   `row[x] == "#"` (`error: '==' compares byte with str`).
9. **`for x in a` walks a range; an array needs `foreach (x in a)`.** Already
   filed as `examples/SUGGESTIONS.md` §5 — the diagnostic is
   `expected '..', got '{'`.
10. **`read_key_timeout(ms)` spends its wait in VTIME, which counts
    deciseconds**, so any non-zero request rounds *up* to the next 100 ms. The
    live view polls with a 0 ms deadline instead: with a 100 ms block per
    iteration every frame was more than a whole period late, the pacer dropped
    it, and the loop settled at 0.6 fps with the generation counter stuck on 1.
    `run_live` says so at the call site.
11. **Exit code for a usage error is 1, not `args`'s 2.** `args.parse_or_exit`
    would exit 2; this program's contract is 1 for every diagnostic, so it calls
    `args.parse()` and applies its own code. One line, commented in `main`.
12. **A record returned by a function allocates on every call** — the same
    mechanism as `SUGGESTIONS.md` §7, one level up. `term.size()` answers
    `{ rows, cols }`, a record literal built fresh per call, so polling it once
    a frame leaked exactly 40 bytes a frame. The frame loop calls this file's own
    `winsize()` instead: the same `TIOCGWINSZ` ioctl (syscall 16, fd, REQUEST,
    arg — kernel register order, §2.1; row first, bytes 0–1, §2.3) into a
    module-level `[byte]`, returned as one packed `rows * 1000 + cols`. The
    std `tui` is not edited; `default_size()` still uses `tui.size()`,
    because it is called once.
13. **`s += t` is amortised O(1), but a frame's worth of `+` is not free.** The
    status line began as `fb.text(surf, s.h, 0, f"gen {s.gen} | …" + f" …")`:
    one f-string, three concatenations and an argument list per frame, which
    measured ~2.4 KB a frame — a program that looks fine for an hour and then
    meets the 3.5 GiB cap. It is now built by `sb_byte` / `sb_str` / `sb_num` /
    `sb_hundredths` into a module-level `[byte; 256]` and drawn with one `fb.put`
    per cell, so a frame allocates nothing. Same discipline as `tui`'s
    `ESC_BUF`, one size up.
14. **`pacer_new()` is a record literal too**, so it costs its own 64 bytes. Not
    a leak (once), but `--stats` measures `heap_used()` in the live path *after*
    the pacer is built, or it reports a constant "64 bytes over N generations"
    that is neither zero nor per-frame — the least useful of the three answers.

Two more choices that are not workarounds but are worth naming: the grid is a
fixed store rather than a growable array partly *because* the heap is an arena
(§2.7) and partly because of (2); and the report's trace and histogram tables
are fixed-size with a stated cap (`TRACE_CAP`/`HIST_CAP`, both reported in
`--stats`) rather than growing per generation, for the same reason.

## Files

| file | what |
|---|---|
| `life.y` | the entry point: flags, the headless report, the live view |
| `sim.y` | the grid, the step function, the built-in patterns, the random pattern (`std/random.y`) |
| `rle.y` | the RLE parser (`{ ok, msg }`, never exits) |
| `fx.y` | `4b47a9bfef0c1e30` | 694 | |
| `capture.sh` | regenerates `EXPECTED` and `golden/` from the pinned compiler |
| `pty_smoke.py` | the five pty sessions above |
| `EXPECTED`, `golden/` | the documented run, and generations as text |

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

## Pin re-verification: `dad3564d3bcdf6df` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`dad3564d3bcdf6df889d017e88660dd8e7e0637a1e046acc45539f515e361d3e`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
