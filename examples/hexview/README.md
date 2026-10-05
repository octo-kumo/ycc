# hexview — a hex editor and file inspector for the terminal

Opens a file, shows it as **offset / hex bytes / ASCII gutter**, pages through it,
and edits bytes in place. Two faces of one model:

* **interactively** — raw mode through std `tui`, drawn through
  `tui`, with a cursor, hex entry, bookmarks, search, an in-place save, and a
  recent-file list;
* **non-interactively** — `--no-tty` prints exactly what
  `od -A d -t x1z -v` prints, byte for byte, and `--check` **proves** that by
  running that program and diffing.

```
build:  ../../refs/ycc.ref hexview.y -o hexview
run:    ./hexview                              the shipped sample, browse it
        ./hexview FILE                         open a file and edit it
        ./hexview --no-tty --hist              the deterministic dump (gate.conf)
        ./hexview --no-tty --file f --width 8 --offset 32
        ./hexview --no-tty --edit 0=ff,1=ee --save /tmp/out.bin
        ./hexview --check                      720 assertions, no child processes
        ./hexview --check --od                 ... and the GNU od cross-check
        ./hexview --bench 20                   throughput, on stderr
```

Nothing is downloaded and the sample file is `embed`ed, so the folder needs
nothing beside it. Built and checked against `refs/ycc.ref` sha256
**9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7**.
That pin moved twice while this example was written (`e55fa8d0…`, then
`9ce37629…`); nothing here depends on which one it is, and the numbers below
were taken on the second.

---

## What to look at

| file | what |
|---|---|
| `hexview.y` | the CLI, the inspector dump, the histogram, and the whole interactive editor |
| `hx.y` | **the model**: a file as `[byte]`, `glyph`, the hex digits, the od-compatible row |
| `selftest.y` | **the property check** — twelve sections, 720 assertions, no reference file |
| `inject.py` | the defect battery: 26 mutations of the source, each caught |
| `pty_check.py` | drives the interactive path through a real pty, with a screen model |
| `gen_data.py` | writes `data/*.bin`; deterministic, no randomness |
| `EXPECTED` | the exact stdout of `gate.conf`'s `run=` line |

Three things are worth reading before the code.

1. **`hx.row` is `od` byte for byte, and that took three measurements.** The row
   is `<offset><' '><two hex digits per byte><pad to 3·W+2><'><gutter><'<`, and
   the pad is **`3·W + 2`**, not `3·W`. It was `3·W`, then `3·W + 1`, before a
   `python3` one-liner counted the columns `od` actually emits at W = 4, 8, 16
   and 32. A dumper that is one column out is byte-identical in every field and
   still does not diff against `od`, which is the only reason anybody would want
   to diff against `od`.
2. **`hx.glyph` is one function and it is the whole gutter property.** `32 <= v
   <= 126` renders as itself; everything else is a dot. Both ends of that range
   are where a hex viewer goes wrong — `0x20` is a space and *not* a
   placeholder, `0x7f` is *not* printable — so `--check` walks all 256 values
   rather than trusting a sample. A golden whose sample contains no spaces
   cannot see this defect at all; the injection battery injects it (M1, M2) and
   both are caught.
3. **`hexview.y`'s key table.** Not one key in it is a hex digit. `a` was bound
   to Home and `f` to "last byte" in the first draft, so `a` and `f` could not be
   *typed* — and a hex editor that cannot type its own alphabet is not a hex
   editor. `pty_check.py` found it by typing a byte and watching the file not
   change; it now types all sixteen digits and reads eight bytes back.

---

## The representation, and why

**Everything is a variable-length `[byte]`. There is not one fixed byte array in
the program's data path.**

This is the decision the task asked to be made explicitly, and it is the
opposite of the one a fixed-size page buffer suggests:

* **A hex editor's whole job is arbitrary sizes.** A `[byte; 4096]` page buffer
  silently caps the file at 4096 bytes; the honest shapes are "read the whole
  file" and "seek per page", and this tool does the first. The ceiling is
  32 MiB, refused with a message (and it keeps the od offset field at seven
  digits, which is what the cross-check compares).
* **`fs.read_bytes` answers `[byte]?` and every reader in `struct` takes a
  `[byte]`.** A fixed array would have to be sliced into a `[byte]` before
  anything could read it — one more copy of the whole file, 56 bytes a slice.
* **`[byte; N]` does not widen to `[byte]`** (`examples/SUGGESTIONS.md` #12), so
  a fixed buffer would force the row formatter to be written once per size. As a
  `[byte]` the file needs no size parameter anywhere, so there is exactly **one**
  fixed array in `hx.y` — `LINE`, the 256-byte formatted-row scratch — and its
  size appears in **no function signature at all**. The cost of #12 is paid once
  instead of twice.
* **A scalar store into a `[byte]` element works and costs zero bytes**, so an
  edit needs no `struct` writer: `hx.set` is `DATA[off] = v`. #9's real content
  is that `struct` has readers with no in-place *setter*; the element store is
  the free way round it, and `selftest.y` measures it (below).

**No page buffer at all.** The interactive view renders straight out of `hx.DATA`
by index. Copying a page out first would have been the other design; it would
have bought nothing and cost a `[byte; N]` plus a widening copy per page.

The consequence worth knowing: **`hx.DATA` is a `[byte]` and a `[byte]` cannot be
put in a record as a variable-size member.** `bmp.Image` in `examples/bmpview`
holds a `[byte; 3145728]` *inside* the record for exactly this reason. Here the
handle is a module-level array and the record-ish state is a set of module-level
scalars (`SIZE`, `DIRTY`, `ERRS`), which is smaller and clearer.

---

## The row format is GNU od's, byte for byte

`hx.row` reproduces `od -A d -t x1z -v`:

```
0000000 68 65 78 76 69 65 77 20 73 61 6d 70 6c 65 00 01  >hexview sample..<
0000016 02 03 7f 80 fe ff 20 20 20 20 20 20 48 65 6c 6c  >......      Hell<
0000032 6f 2c 20 68 65 78 21 00 09 0a 0d 21 22 7e 7e 30  >o, hex!....!"~~0<
```

* the offset is `%07d`, which is od's fixed width;
* the hex field is padded with spaces to **`3·W + 2`** columns from the separator
  space, so the `>` lands in the same column on a short last row;
* the gutter is the actual bytes on the row, so a partial row's gutter is
  *short*, exactly as od prints it;
* **one trailing line, the file's length as a bare offset, always** — including
  for a zero-length file, where it is the *only* line. That is the one a reader
  forgets;
* lowercase hex digits.

Two deliberate differences from `od`, both of them the right call for an editor:

* **no `*` collapse.** GNU `od` replaces repeated identical rows with a single
  `*` unless `-v` is given. A hex editor must show every byte — that is the
  entire product — so `zeros48.bin` is in the cross-check family precisely to
  make the difference visible, and the cross-check passes `-v` so the two are
  comparable.
* **no line for a file over 10 MiB's seven-digit offsets.** od would widen; the
  32 MiB ceiling keeps this program's field at seven digits, and `hx.row` grows
  the field with `hx.digits(SIZE)` if it ever needs to. That growth is **not**
  cross-checked, because nothing here can produce a file big enough to need it
  inside the memory cap.

---

## Keys

```
arrows / hjkl   move the cursor        tab      hex pane / gutter pane
0-9 a-f         type a byte, nibble by nibble
g / G           first / last byte      m        bookmark on / off at the cursor
[ / ]           previous / next bookmark        x   clear every bookmark
/               search for ASCII in the buffer   n / N   next / previous match
o               open another file (a recent-file ring, newest first)
w               write the buffer back to the file it came from
q or escape     quit
```

**No key in that table is a hex digit.** `b` was the bookmark key in the first
draft, which made `b` untypeable; `a` was Home and `f` was "last byte". All three
were found by `pty_check.py`, which now types `0123456789abcdef` and asserts the
screen reads `01 23 45 67 89 ab cd ef`.

Every exit goes through `term.restore_all_exit()`, and the watchdog is armed, so
a crash or a `kill -9` still puts the terminal back. `pty_check.py` asserts
`c_lflag` is byte-identical before and after on the **error** paths too.

### There is no `push`, no `sort`, no map — so both lists are hand-rolled

* **Bookmarks** are one module-level `MARKS: [long; 64]` with a linear duplicate
  scan (`mark_find`), a toggle that shifts down (`mark_toggle`), a wrap-around
  `mark_step`, and "full means the oldest goes". No allocation, ever: the array
  is fixed and the bookkeeping is integers.
* **Recent files** is a variable-length `[str]` kept at eight entries. There is
  no `push`, so `RECENT *= p` **prepends** and the tail is dropped with a slice
  — which is the whole array interface, used where the language has nothing else
  to offer. It costs one array per *open*, at most a handful of times in a
  session and never in the frame loop.

---

## No per-frame allocation — measured, not asserted

The heap is an arena and nothing is ever freed (`ORCHESTRATOR.md` 2.7), so the
frame loop holds no literal and builds no string. `--frames N --time` prints the
heap delta across the frames it drew:

| frames drawn | heap delta |
|---|---|
| 1 | 504 B |
| 5 | 504 B |
| 10 | 512 B |
| 60 | 512 B |
| 240 | **520 B** |
| 480 | **520 B** |
| 1000 | **520 B** |

**520 bytes, and it does not grow**: 1000 frames cost the same 16 bytes more
than 5 frames do. The step is `fb.resize` on the first frame plus two 8-byte
steps somewhere between 60 and 240 frames — the arena's granularity, not a leak.
The number that matters is the *shape*, not the constant: a per-frame allocation
would be 136 B/frame here and 1000 frames would be 136 000 B.
Every buffer is module-level and sized by a literal at module scope: the surface,
the 64 KiB stdout buffer, the 256-byte row scratch, the status-line byte buffer,
the winsize scratch, the digit scratch.

**That 512 was not always 512.** The key-help line was

```y
sbs("arrows/hjkl move  ... [ ] mark  "
    + "/ find  n N next  o open  w write  f fit  q quit");
```

one call with a `+` between two literals. `sbs` takes a `str`, so the
concatenation built a fresh heap string **every frame**: 136 bytes a frame, 16 KB
a minute. It is the string form of the hard rule in `ORCHESTRATOR.md` §2.7 ("hoist every
literal out of every loop"), and it is invisible in a golden. Two `sbs` calls
fixed it. `--frames 120 --time` is what measured it; the numbers above are the
"after".

`term.read_key_timeout(0)` is the poll and `tui`'s pacer owns the deadline
(`VIEW_FPS = 30`) — a 1..99 ms poll rounds up to 100 ms because `VTIME` counts
*deciseconds*, and every frame then lands a period late. The resize poll is a
module-level `TIOCGWINSZ` into `WSBUF`, not `term.size()`, which returns a fresh
record (~40 B) per call.

**The quadratic audit, done the cheap way.** Compiled with `-S`, counting two
symbols per function — `call y_str_app` is the amortised in-place append,
`call y_str_cat` the exact-size copy that is quadratic in a loop:

```
hx.row  cat=0 app=0     hexview.draw_row      cat=0 app=0
hx.glyph cat=0 app=0    hexview.draw_status   cat=0 app=0
hx.putb  cat=0 app=0    hexview.draw_title    cat=0 app=0
hx.put_off cat=0 app=0  hexview.sput          cat=0 app=0
                        hexview.draw          cat=0 app=0
```

The entire frame path is zero for both. The `cat` counts that exist are all in
`main`, `apply_edits`, `selftest.*` and `hx.open_path` — one-time paths and the
check, which is allowed to build strings because it runs once. There is no `+=`
on a `str` anywhere in this program, so the value-position `+=` quadratic cannot
arise here at all.

### Throughput

`--bench N` times N passes of the row formatter over the open file and reports
MB/s in integer thousandths (no float, and the arithmetic is written out in the
code — the first draft carried a stray `1000` twice and claimed 54 GB/s).

| input | passes | rows | time | rate |
|---|---|---|---|---|
| 1 MiB generated | 20 | 1 310 720 | 396–404 ms | **51.8–53.0 MB/s** |
| 256 B (`all256.bin`) | 20 000 | 320 000 | 77 ms | **65.8 MB/s** |

A whole 1 MiB dump — 4 980 823 bytes of output over 65 539 lines — takes
**0.03 s wall, 5 072 KiB max RSS**, and that is dominated by `write(2)`, not by
the formatter.

### Heap

| | heap used |
|---|---|
| baseline (fixed cells, the vendored toolkit, the 256 KiB `fb` capture buffer) | **1 935 472 B** |
| with a 1 MiB file open | **5 082 800 B** |
| interactive, 1000 frames drawn | **+520 B** |

The file costs its own size and nothing else; there is no second copy of it
anywhere, in the dump path or the frame path.

---

## The property check — the deliverable

`./hexview --check` is **720 assertions in twelve sections, with no reference
file involved.** It does not read `EXPECTED`, it does not read a fixture of
"known good output", and every expected value is written out in `selftest.y`
from something outside the code under test: a literal table, a hand-computed od
line, a count taken from `fs.file_size` (i.e. from the operating system), or GNU
`od` itself.

```
$ ./hexview --check --od
hexview property check
  toolkit-free model: hx.y holds a file as [byte]; the row format is
  GNU od -A d -t x1z -v, reproduced byte for byte
[1 the ASCII gutter, all 256 byte values]
[2 the hex digits, all 256 byte values]
[3 one fixture's dump, against four hand-written lines]
[4 round-tripped edits: write, save, re-read with a fresh reader]
[5 struct's u32 readers against two hand compositions]
[6 bounds: every hostile offset is a value, not a trap]
[7 the histogram conserves the byte count]
[8 the histogram hexview prints, cell by cell]
[9 the row formatter is deterministic]
[10 the summary line's own numbers, at eight --rows values]
[11 the GNU od cross-check: od -A d -t x1z -v, byte for byte]
  15 of 15 dumps identical to od, 29458 bytes compared against 29458 bytes of od output
[12 every flag's error path: non-zero exit, ITS OWN message, no trap]
  720 assertions, 0 failed
  od cross-check: 15 files, 29458 bytes identical to od -A d -t x1z -v
hexview --check: every property held
```

### The oracles

| § | what it asserts | where the expectation comes from |
|---|---|---|
| 1 | the gutter for **all 256** values, and the class counts 95 / 161 | the definition of printable ASCII; `0x20`, `0x7f`, `0x00`, `0xff` named |
| 2 | both hex digits of all 256 values, and `hexval` as their inverse | a **literal 16-entry string table** in `selftest.y`, plus a rejection list |
| 3 | one 48-byte fixture's dump | **four hand-written lines**, confirmed by §11 |
| 4 | **edits round-trip**: write, save, re-read with a **fresh** `fs.read_bytes` | the literal fixture and a literal edit list; the total from `fs.file_size` |
| 5 | `struct`'s u32 readers | two hand compositions of the same four bytes |
| 6 | every hostile offset is a **value** | the bounds, named |
| 7 | the histogram conserves the byte count | `fs.file_size`, not `hx.SIZE` |
| 8 | the histogram **the program prints**, all 256 cells | counts computed from the file's bytes, total from the OS |
| 9 | two passes produce the same bytes | itself, twice |
| 10 | the summary line's own numbers at eight `--rows` values, and the boundary at `--offset 96` | `hx.plan_rows`, and the dumped line count |
| 11 | **the dump vs `od -A d -t x1z -v`** | GNU coreutils, C, decades apart |
| 12 | every flag's error path | non-zero exit, **that flag's own message**, no trap |

### The `od` cross-check, in detail

`--check --od` writes a family of **fifteen** files — the three shipped fixtures
plus twelve generated — asks `od -A d -t x1z -v` for each, asks **this program,
as a child process**, for each, and compares the bytes.

| file | bytes | why it is in the family |
|---|---|---|
| `data/sample.bin` | 96 | the shipped one: a NUL in the middle, a 0x7f, the top four byte values, four runs of `0x20`, **no trailing newline** |
| `data/all256.bin` | 256 | every byte value, sixteen rows |
| `data/zeros48.bin` | 48 | three **identical** rows — what `od` collapses to `*` without `-v` |
| generated | 0 | no rows at all; the size line is the only line |
| generated | 1 | everything degenerate at once |
| generated | 5, 7 | short last rows |
| generated | 15 | one byte short of a row, so the size line is not a row |
| generated | 16 | exactly one row |
| generated | 17 | a one-byte last row |
| generated | 48 | the 0x00..0x0f / 0xf0..0xff / 0x20..0x2f ramp, three rows |
| generated | 257 | all 256 values plus one, so a row count of 17 is not 16 |
| generated | 1000, 4096 | an LCG, so 63 and 256 rows with no two alike |

Result: **15 of 15 dumps identical, 29 458 bytes compared against 29 458 bytes of
od output.** If `od` is not installed the section says `SKIPPED` loudly on its own
line and the summary says so — it does not quietly compare nothing.

### Round-trip edits, and the bug that only a fresh reader sees

§4 writes the 48-byte fixture, edits **ten** offsets (including 0, a row
boundary, and the last byte), saves to a *different* path, and re-reads with a
**new** `fs.read_bytes` — a new array, nothing shared with the buffer that was
edited. It then compares every byte against a literal expectation and asserts:

* the saved file's length, **from `fs.file_size`**, not from `hx.SIZE`;
* that the pattern differs from the original at **exactly ten** offsets, so a
  save that wrote nothing cannot pass;
* that the file it did **not** save to is still the original, so a check that
  compared the buffer with itself would fail;
* that `hx.save` created **the path it was told to**, and did not write the bytes
  beside it;
* a **second** round trip over a different pattern, so a save path that works the
  first time by accident is not enough.

An edit that appears to work in the buffer but is never flushed is invisible to a
golden *and* to any comparison of the buffer with itself. This is the only
oracle for it, and it caught a real defect in the check itself (see M10 below).

### Defect injection: 26 injected, 26 caught

`python3 inject.py` makes an **exact single-occurrence string replacement** in a
**copy** of the folder, builds the copy with the pin, and runs **two** oracles
against it: `./hexview --check --od` and `python3 pty_check.py ./hexview`. A
defect neither oracle notices is a defect the example cannot find, and saying
"the check passes" without doing this is the failure mode `day08` set the
standard against.

| # | injected defect | caught by | first assertion to fail |
|---|---|---|---|
| M1 | the gutter's low bound `32 → 33`: a space becomes a placeholder | `--check` | every one of 256 byte values renders right: first at 32: got 46, want 32 |
| M2 | the gutter's high bound `126 → 127`: DEL becomes printable | `--check` | every one of 256 byte values renders right: first at 127: got 127, want 46 |
| M3 | hex digits a–f come out as `':'…'_'` | `--check` | both digits of every byte value match the literal table: first wrong at 10 |
| M4 | the a–f base is off by one: `f` prints as `e` | `--check` | both digits of every byte value match the literal table: first wrong at 10 |
| M5 | the hex field is one column short of od's | `--check` | dump line 0: got […01 >…] want […01  >…] |
| M6 | a byte's two nibbles print in the wrong order | `--check` | dump line 0: got `00 10 20 30 40…` |
| M7 | a short last row is padded one column too few | `--check` | dump line 0 |
| M8 | `byte_at` accepts `offset == SIZE` | `--check` | **a trap**, not an assertion: `runtime error: index out of bounds` |
| M9 | `set` accepts `offset == SIZE` | `--check` | **a trap**: `runtime error: index out of bounds` |
| M10 | `save` writes to `path + ".tmp"` — an edit that never reaches the file | `--check` | the save created the file it was told to |
| M11 | `hexval` accepts a third digit: `--edit 0=ffff` silently means `0xff` | `--check` | hexval refuses three digits: got 255, want −1 |
| M12 | the trailing size line reports one byte too many | `--check` | dump line 3: got `[0000049]`, want `[0000048]` |
| M13 | `--width 32` is refused | `--check` | `--width 32 --rows 2` ran |
| M14 | the dump advances by `WIDTH + 1` | `--check` §11 | shipped `data/sample.bin`: line 1 differs from od's |
| M15 | `plan_rows` rounds up even on an exact number of rows | `--check` §10 | `--rows 0`: the summary's row count: got 7, want 6 |
| M16 | `--edit` refuses every field after the first | `--check` | the two-edit `--save` case succeeds: got 2, want 0 |
| M17 | the histogram buckets `0xff` into `0x00` | `--check` §8 | row 0 col 0: printed 3, want 2 |
| M18 | `--offset` accepts up to `SIZE + 16` | `--check` §12 | `--no-tty --offset=97`: exited 0 |
| M19 | `--edit`'s 16-hex-digit bound on the offset is gone | `--check` §12 | `--no-tty --edit 1000000000000000000=ff`: exited 0 |
| M20 | an edit stores one byte less than it was given | `--check` §4 | every byte on disk is the byte that was written: offset 0: on disk 254, expected 255 |
| M21 | the gutter's placeholder is `?` instead of `.` | `--check` | the placeholder is '.': got 63, want 46 |
| M22 | `save` never clears the dirty flag | `--check` §4 | saving cleared the dirty flag: got 1, want 0 |
| M23 | typing a byte stores only the **low** nibble | `pty_check` | the hex-alphabet session: `01 23 45 67 89 ab cd ef` |
| M24 | the view's offset column drops a digit | `pty_check` | six of six row offsets on screen |
| M25 | `G` jumps to the first byte instead of the last | `pty_check` | status line after `G`: `off 0x5f` |
| M26 | the bookmark key always **adds**, so a toggle never removes | `pty_check` | marks back to 0 |

**M8 and M9 are caught by the check *dying*, not by an assertion, and that is
the weaker claim.** Widening a bound check by one turns an out-of-range read into
a trap, and the process exits non-zero, so `--check` fails — but no assertion
names the defect. `inject.py` classifies those two separately
(`caught --check (trap)`) rather than counting them as the rest. They are still
real catches: a trap on a hostile offset is precisely what gate item 3 and
`ORCHESTRATOR.md` §2.6 exist to prevent, and without the bounds section the same
mutation would reach the interactive path.

**Three of these were found by the battery in the *check*, not in the program**,
and fixing them is the reason the battery is worth more than a claim:

* **M10 exposed two things, both in the check.** The round trip ran in `/tmp`, so
  a file left by an earlier run was still there when it started; with `save`
  writing to `path + ".tmp"` the fresh reader read the *old* file and every
  assertion passed. §4 now deletes the paths first and says they were absent. And
  the *first* time the fix was in place M10 was still reported as a trap rather
  than as its own assertion: `ck(sz2!, FIXN)` unwrapped a `none` from
  `fs.file_size` before the assertion that names the defect could run, and
  `ok(...)` records a failure without stopping. Every `!` on a
  `file_size`/`read_bytes` answer is now behind a guard, so a check that finds a
  defect **reports** it instead of dying on it — which is the whole point of
  having one.
* **M17 and M18 exposed two blind spots.** §7 checked a histogram `selftest.y`
  counted *for itself*, while the one `hexview.y` prints and `EXPECTED` holds had
  no oracle at all — that is §8 now. And the `--offset` boundary was only tested
  100 000 bytes past the end, well outside M18's slack — `--offset=97` and
  `--offset=100` are in the table now.
* **A fourth was structural and is worth reading on its own: the whole error-path
  table was vacuous.** Every case ran the program *bare* (`--width=-1`, no
  `--no-tty`), and with a non-terminal stdin `run_interactive` refuses to start
  and exits 2 with "not a terminal" — so all 31 cases "passed" for a reason that
  had nothing to do with the flag. Thirty-one vacuous passes, invisible to every
  other gate item, and found only because M18 changed something the table could
  not see. §12 now puts `--no-tty` in **every** case and asserts **that flag's own
  message**, plus a guard that the output does *not* contain "not a terminal".

### What this battery provably cannot catch

Named rather than left implied:

* **The vendored toolkit.** `inject.py` mutates only `hx.y` and `hexview.y`. A
  defect in `tui` or `args` is out of scope by
  construction — they are byte-identical copies of `examples/_toolkit/` and must
  not be edited. `pty_check.py` exercises them heavily but cannot attribute a
  failure to them.
* **`struct`'s readers are an oracle, not a subject.** §5 checks `struct` against
  two hand compositions; a bug *shared* by all three would pass. That is why the
  two compositions are little-endian and independently spelled — the first draft
  had both of them **big-endian**, so they agreed with each other on every word
  and disagreed with `struct` on every word, and §5 caught it. Two oracles that
  share a mistake are one oracle.
* **The od cross-check skips if `od` is absent.** Loudly, on its own line and in
  the summary — but on a machine without coreutils, §11 contributes nothing.
* **A mutation applied to `selftest.y` as well as the code.** `inject.py` edits
  one exact string in one file. A "defect" that weakened an expectation would
  prove nothing, so it is not attempted.
* **Absolute memory.** Nothing asserts an allocation *ceiling*; the campaign cap
  (`ulimit -v 3.5 GiB`) is the check, and the flat heap delta above is the
  evidence for the frame path.
* **Concurrency.** There is none, so there is nothing to be nondeterministic
  about. The `EXPECTED` run is a single-threaded dump; `--check` spawns child
  processes sequentially.

---

## Every hostile input is a message and a non-zero exit

Runtime traps print to **stdout** and would land in a golden diff looking like
program output (`ORCHESTRATOR.md` §2.6), so every one of these is a value:

| input | answer |
|---|---|
| a zero-length file | the size line `0000000` and nothing else; `--check` §6 |
| a file shorter than one row | the hex field padded to width, the gutter short |
| a file that is not a multiple of the row width | ditto, on the last row only |
| not valid UTF-8 | irrelevant — nothing decodes it; `0x80`–`0xff` are dots |
| a binary file with no trailing newline | `data/short.bin`, and `sample.bin` |
| an offset or edit before the start | `E_NEG` → a message, exit 2 |
| an offset or edit at or past the end | `E_PAST` → a message, exit 2 |
| a value outside 0..255 | `E_RANGE` → a message, exit 2 |
| a path that is not there / is a directory / is a device | `hx.open_path` refuses all three with a message |
| a save to a directory that does not exist | `cannot write`, exit 2 |
| `--width`, `--rows`, `--frames`, `--bench` out of range or negative | a message, exit 2 |
| an unknown option, an option with no value, a non-numeric value | `args`' message on **stderr**, exit 2 |
| `--edit` with a bad offset, value, width or arity | a message, exit 2 |
| two files at once | a message, exit 2 |

Two shapes worth calling out:

* **`--offset` equal to the file's length is ACCEPTED** — it plans no rows and
  prints the size line alone, which is a legitimate "seek to the end". Anything
  *beyond* the length is refused. §10 pins it from the output side and §12 from
  the exit-status side, because a boundary is exactly where an off-by-one hides.
* **A usage error's message goes to stderr, never stdout.** `args.ar_fail` writes
  its message to stderr and answers `USAGE`; hexview must then exit 2 and put
  its *usage text* on stderr too. The first draft printed the usage on stdout
  and returned 0, which `inject.py` caught as M13-family behaviour.

`main()`'s return value is not the exit status, so the entry point is
`exit(main())`, and `main` returns `0` / `2` / `3` / `4` deliberately:
`2` is a usage or input error, `3` is a failed `--check`, `4` is the internal
"planned rows ≠ printed rows" inconsistency, `5` is a failed `write(2)`.

---

## The std units this uses

Copied byte-identical from `examples/_toolkit/` with `cp`, never edited:

`fx.y` is **not** vendored: a hex editor does trigonometry and square roots
never. Nothing in this folder imports across folders.

---

> **Note for the orchestrator:** `SUGGESTIONS.md` #19 ("A fixed `[T; N]` is not
> usable where `[T]` is expected, so a helper cannot take a buffer") reads like a
> second statement of **#12** ("A `[byte; N]` does not unify with `[byte]` …").
> It is not this example's filing and I did not touch it, but the two look like
> one gap under two titles and probably want merging.

## Compiler workarounds, and where each is filed

Every one of these is in the code, with a comment naming the filing or the
measurement.

| workaround | where | why |
|---|---|---|
| one fixed `[byte; 256]` scratch and no size parameter anywhere | `hx.y`, `hx.row` | `SUGGESTIONS.md` **#12** — a `[byte; N]` does not widen to `[byte]`, so a helper that takes a buffer names its size. Making the scratch module-level means the size appears in **no signature** and the cost is paid once. |
| `FIX[0:48]` and one fixed cell per fixture size, and **four** copies of the same fill loop (`fill16`/`fill256`/`fill1024`/`fill4096`) | `selftest.y` §4 | the same **#12**, plus **#8** — `[0; n]` wants an integer *literal*, so a fixture of a runtime length cannot be declared at all. This is #12's concrete price, paid in a check that runs once. |
| `DATA[off] = v` for an edit, with no `struct` writer | `hx.set` | `SUGGESTIONS.md` **#9** — `struct` has readers that cost nothing and no in-place setter. The element store on a `[byte]` costs **zero** bytes: 20 000 of them in a loop measure **0 B**. I appended a narrowing note to #9 recording that the gap is only for scalars *wider* than a byte, so the one-byte case is not cited as motivation for `put_*`. |
| `hx.hexval` / `hx.decval` refuse what they do not understand | `hx.y` | `SUGGESTIONS.md` **#4** — `tonum` is decimal-only and answers **0** for text it does not understand, which for a byte value is silent corruption. `--edit 0=zz` would write `0x00` and look like it worked. |
| the status line is one `[byte; 256]` and `sbw`/`msgn` append to it; **two `sbs` calls instead of one call with a `+` between two literals** | `hexview.y`, `draw_status` | `examples/BUGS.md` — the `str +=` in a value-used position is O(n²) in heap — and the narrower case measured and filed as `examples/SUGGESTIONS.md` **#20**: a `str` built by `+` from constants inside a loop body allocates **48 bytes an evaluation**, while the same concatenation in a `const` costs 0. Measured here: 136 bytes a frame before, 0 after. |
| `sput` walks the byte buffer into the surface cell by cell instead of calling `fb.text` | `hexview.y` | `ORCHESTRATOR.md` 2.7 — `fb.text` plus a freshly built `str` is ~2.4 KB a frame. |
| a module-level `TIOCGWINSZ` read instead of `term.size()` | `poll_winsize` | `term.size()` returns a fresh record (~40 B) per call, and a per-frame resize poll leaks. |
| `read_key_timeout(0)` plus `tui`'s pacer | `run_interactive` | `ORCHESTRATOR.md` 2.1 — `VTIME` counts deciseconds, so a 1..99 ms poll rounds up to 100 ms and every frame lands a period late. |
| `&buf[i]` for the `syscall(1, 1, …)` in the buffered writer and in `selftest.say` | `hexview.y`, `selftest.y` | `syscall` accepts a `*byte` and `&buf[i]` yields one; `p + got` on a `*byte` is the missing half of **#12**, so the offset is carried in the index instead. |
| `hexview --check` needs `exec`, so it needs a binary **not** built with `ycc --no-exec` | `gate.conf` | `exec` is spliced in only when the program mentions it, and `--no-exec` omits it entirely. Sections 1–10 and the `EXPECTED` run need nothing. |
| a guard flag with an explicit terminal assignment for early exit | `selftest.y` §10 | there is no `break` and no `continue` in this language (`ORCHESTRATOR.md` §2.10). |
| byte literals written as numbers (`K_Q = 113`), never `'q'` | `hexview.y` | no character literals: `'a'` is a lexer error, the form is `c'a'`. |

**Filed, both narrow and both measured, neither a bug:**

* `examples/SUGGESTIONS.md` **#20** (new) — a `str` built by `+` from constants
  inside a loop body allocates 48 bytes an evaluation; the constant folder
  already folds the `const` form (0 B) and just does not reach the `+` in a loop
  body. The string arm of #7, which measures only array and record literals.
* `examples/SUGGESTIONS.md` **#9** — a **narrowing note appended**, with the
  measurement: `DATA[off] = v` is free, so #9's real scope is scalars wider than
  a byte and its title overstates it. Existing text untouched; nothing renumbered.

Nothing is filed as a **compiler bug**, because nothing found here is one. The
gap that is real — a `[byte; N]` that will not widen to a `[byte]`, so a buffer
helper has to be written once per buffer size — is already `SUGGESTIONS.md` #12,
and the gap that would have been the interesting one, *no in-place scalar writer
into a `[byte]`*, turns out not to exist: `DATA[off] = v` is the element store
and it is free. That is recorded in #9's own territory rather than refiled.

---

## The data files

`gen_data.py` writes `data/*.bin` deterministically, with the layout of each
byte stated in a table in the script and asserted as it goes, so a segment that
grows breaks the build instead of silently shifting everything after it.

| file | bytes | what it breaks |
|---|---|---|
| `sample.bin` | 96 | a NUL in the middle, a `0x7f`, the top four byte values, four runs of `0x20`, a full row of identical bytes, **no trailing newline** |
| `all256.bin` | 256 | every byte value in sixteen rows |
| `zeros48.bin` | 48 | three identical rows — what `od` collapses to `*` without `-v` |
| `short.bin` | 5 | a NUL, the top byte value, a space, and a last row shorter than the width |
| `one.bin` | 1 | everything degenerate at once |

`sample.bin` is also `embed`ed into `hexview.y`, so `./hexview` with no
arguments always opens the same bytes.

---

## Reproducing all of it

```sh
cd examples/hexview
../../refs/ycc.ref hexview.y -o hexview          # build, zero warnings
./hexview --no-tty --hist </dev/null | diff - EXPECTED && echo golden ok
./hexview --check </dev/null                     # 720 assertions, no children
./hexview --check --od </dev/null                # + 15 files vs GNU od
python3 pty_check.py ./hexview                   # the interactive path, real pty
python3 inject.py                                # 26 defects, 26 caught
python3 ../gate.py hexview                       # the eight gate items
```

Everything runs under `ulimit -S -v 3670016` with `</dev/null`.
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
