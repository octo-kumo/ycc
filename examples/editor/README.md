# `editor` — a Vi-style modal terminal editor, in Y

A modal text editor that runs in a terminal and writes a static ELF with no libc
underneath it. NORMAL / INSERT / VISUAL modes, a `:` command line, motions,
operators, text objects, undo with a real history, and a whole-file substitute.
It is about 5 000 lines of Y across five files, plus a frozen copy of three
toolkit modules (1871 lines) it does not edit.

The thing that makes it worth reading is that **it ships its own correctness
check**. `EXPECTED` proves the renderer is deterministic; `check.y` proves the
editor is *right*, with 1 868 assertions and no reference file involved — an undo
invariant checked byte-for-byte, a substitute whose count is held against the
standard library's own independent implementation, boundary safety at every edge
of the buffer, and a second model of the buffer kept in a different
representation and compared after every single edit. That check found four real
bugs in this editor while it was being written, listed at the bottom.

---

## Build and run

The compiler is pinned; build with it and nothing else.

```
$ ../../refs/ycc.ref editor.y -o editor        # the whole program
$ ./editor data/demo.txt                       # interactive, needs a terminal
$ ./editor --no-tty --keys 'ggdd:wq' data/demo.txt    # scripted, diffable
$ ./editor --check                             # the property checks
$ ./editor --bench 5000                        # heap + redraw cost
$ python3 pty_test.py                          # drive it through a real pty
```

`gate.conf` names the two the gate runs:

```
build=../../refs/ycc.ref editor.y -o editor
run=./editor --no-tty --keys 'gg0ciwone<Esc>A! and more<Esc>u<C-r>jddG:%s/o/0/g<CR>:u<CR>:3<CR>Vjy$pdiwA;<Esc>G0ci"two<Esc>gg0$:wq golden/demo-written.txt<CR>' --rows 10 --cols 44 data/demo.txt
check=./editor --check
pty=python3 pty_test.py
```

**Compiler pin.** Built and measured against

```
refs/ycc.ref sha256 1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3
```

`gate.py` item 0 fails if that stops matching, and this README records it on
purpose. The pin moves on every rebless; if it moves, rebuild, re-run both
modes, and put the new sha here.

**The pin moved twice while this file was being written**, and both moves were
checked rather than assumed. It was `c53cc41524a7baa2`, then
`625efd81934531f6`, and it is now `1d28b3dbcc546b5fc`. Under the current pin
`EXPECTED` reproduces byte for byte over two runs, its sha256 is unchanged
(`eea36bdac1421aefcc3285b292c7c5146e72a7eccf4193ed5e0d87720ecebaa5`), the file
`--no-tty` writes has the same sha256 as before
(`7a02e3409308f517288bf0e40ee8416f8d72785fffcc35ea6ceb556966ed4a97`), and
`./editor --check` reports 1 891 of 1 891. A rebless that had changed either
would have been a real finding, and there was none.

**Build it in place.** Do not copy `refs/ycc.ref` somewhere else to keep it:
`buf.y` does `import fs;`, and a copy of the binary a directory away compiles
every other module and then fails with `error: cannot find module 'fs' (import
name; looks next to the importer and in std/)` -- the compiler resolves its std
relative to its own path. That is ORCHESTRATOR.md 3, not a bug, and it cost one
confusing build here.

**Frozen toolkit.** Vendored byte-identical from `examples/_toolkit/`, revision
as of 2026-10-04:

| file | sha256 | lines | why |
|---|---|---|---|
| `term.y` | `07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee` | 1156 | raw mode, key decode, window size, alt screen, restore-on-every-exit |
| `args.y` | `cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28` | 19081 | flag parsing, usage text, exit codes |
| `time.y` | `6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b` | 245 | the clock and the microsecond nap |

**`fb.y` is deliberately NOT vendored — but that is now a choice, not a
workaround, and the original reason no longer holds.** It was written when
`fb.y`'s `emit_num` dropped interior zeros, so every SGR channel and every
CUP operand in the 100–109 range was emitted wrong (`101` arrived as `11`).
An editor's entire job is emitting CUP at arbitrary row/column positions,
so that was a real reason to refuse the module. **It was fixed
campaign-wide** — `emit_num` now finds the highest decimal place first and
emits every place down to units — and verified against this folder's use:
the current `fb.y` writes `ESC [ 106 ; 108 H` for cell (105, 107), where
the old one wrote `16;18`. See `examples/BUGS.md`, "`fb.y`'s `emit_num`
drops a zero digit", and the regression test now in
`examples/_toolkit/fb_test.y` §8 that pins `203;101;100` and friends.

So `screen.y` keeps its own single `[byte; 262144]` frame buffer and one
`write(2)` per frame — a defensible design for a full-screen editor that
wants row-diffing under its own control, but no longer a bug workaround,
and it is recorded here as a decision rather than dressed up as one.
Nothing here imports across folders.

**Artefacts.**

| file | what |
|---|---|
| `EXPECTED` | 1 616 B — the exact stdout of the `run=` line above |
| `golden/demo-written.txt` | 468 B — what that run's `:wq` wrote; committed so the run is idempotent |
| `golden/pty-capture.txt` | 15 KB — the raw bytes a real pty received, from `pty_test.py` |

---

## What to look at

### The golden screen

`EXPECTED` opens with the screen, in a ruled box, exactly as the editor painted
it:

```
+--------------------------------------------+
| 1 own fox jumps over the lazy dog! and more|
| 2 amma delta epsilon zeta eta theta        |
| 3 e four five six seven eight nine ten     |
| 4 repeated repeated repeated words in it   |
| 5 epeated repeated repeated words in it;   |
| 6                                          |
| 7                                          |
| 8 he file                                  |
| 9 h four spaces                            |
|-- NORMAL --                                |
+--------------------------------------------+
--- buffer  14 lines, 468 bytes ---
```

Three things in there are worth checking by eye:

* **Row 1 is cut off on the left** (`own fox jumps…`). That is the horizontal
  scroll: the window is 44 columns, the gutter takes 3, so the text area is 41,
  and the cursor is at byte 52 of that line. `scroll    top 0  hcol 12 gutter 3
  textw 41` in the state section is the arithmetic.
* **Every row is padded to the full width**, so a stale character from a
  previous, longer frame cannot survive behind a shorter line. A trailing `\r`
  from the terminal's own `OPOST` would do the same; full-width repaint does not
  depend on the emulator.
* **`^I` for the tab**, `café naïve résumé coöperate` on its line, and `~` below
  the end of the file.

### The property check

```
$ ./editor --check
property checks -- seven groups, no reference file involved
        seed 1
        an index trap prints its message on STDOUT, so it would show up here
        as a MISSING line rather than an error; surviving is part of the check

        after 10 edits: 29 bytes, hash 10952.82
        original hash 3963.7
        fuzz: 100 edits, 100 undo entries, hash 64995.67
        bound: 400 edits, undo depth capped at 128
        the closing delimiter is what removes that ambiguity: s/hit/big/ -> "big big"
        model: 500 edits, final 3 lines 10 bytes, hash 63980.2

  (a) undo invariant                    115 checks
  (b) substitute correctness            453 checks
  (c) boundary safety                   723 checks
  (d) independent model                  513 checks
  (e) viewport minimality               26 checks
  (f) utf-8 column algebra              38 checks
  (g) input file error path             23 checks
== 1891 checks, 1891 ok, 0 failed ==
```

Exit 0, byte-identical across runs, and identical for `--seed 1 2 7 999983
2147483646`. What each group is for is in `check.y`'s header; the short version:

| group | what it proves, and how it avoids being a restatement of the code |
|---|---|
| **(a) undo invariant** | N edits then N undos returns the text **byte for byte**, compared as text *and* printed as a hash. 100 fuzzed edits too, plus a separate assertion that 400 edits leave exactly the capped number of entries. Also: a typed run is **one** undo entry, which a count of "things that happened" would not distinguish. |
| **(b) substitute** | The oracle for the global case is the std's own `str.replace` / `str.count` — KMP, sharing no code with `buf.y`'s naive scan — and the count the command *reports* is checked against the number of replacements actually made. |
| **(c) boundary safety** | ~150 hostile keys driven through the **real** `modes.feed()`, with every cursor and viewport invariant asserted after **every key**, on an empty buffer and again in a window too small for the content. Plus a sweep of 20 screen geometries through the painter, and specific boundary behaviours asserted rather than merely survived (`dd` on a one-line buffer, `X` at column 0, `p` with an empty register, `:q` on a modified buffer, `ci"` with no closing quote). |
| **(d) independent model** | The same edit sequence applied to a reference model kept in a **different representation** — one flat string with LF splices, against `buf.y`'s array of per-line strings — compared after every one of 500 fuzzed steps. |
| **(e) viewport** | `hcol` is **minimal** at every column of a long line and `top` at every line, and is zero exactly when the cursor fits from column 0. A golden file cannot see this: a dump that only ever scrolls one way looks identical whether the offset is right or wrong. |
| **(f) utf-8** | `adv`/`snapb`/`prev_start`/`$`/`w`/`l`/`x` step whole code points, and a code point is **one screen column** — asserted through the cell grid, not through the byte stream. |
| **(g) input file error path** | The only group that runs the built binary, because the claim is about an exit code and about *which stream* a message came out of. A named file that cannot be read must exit non-zero, say so on stderr naming the path, and print **nothing** on stdout; the same script on the file that *is* there must exit 0, carry the file's own text into the dump and report the key count. A script cut short by `:q!` must report the keys it ran, not the keys it was handed. Reintroducing the defect makes this group report 5 failures and exit 1 — measured, not asserted. |

### The keys

```
NORMAL   h j k l w b e 0 ^ $ gg G { }  <Left> <Right> <Up> <Down> <Home> <End> <PgUp> <PgDn>
         i a A o O  x X  ~  J  p P  u  ^R  V  n N  / ?  :  Z
operator d c y  +  a motion | gg G { } j |  i w  a w  i"  a"  |  doubled: dd yy cc
ex       :w :w FILE :w!  :q :q! :wq :wq FILE :x  :s/pat/rep/ :s/pat/rep/g  :%s/// :N  /pat ?pat  :u :redo
```

`V` is linewise visual only — there is no `v`, and the README says so rather than
implying a characterwise mode that is not there.

### The source

| file | lines | what is in it |
|---|---|---|
| `buf.y` | 1469 | the document, the cursor, the viewport, the change log, motions, operator ranges, substitute, UTF-8 column algebra, file load/save |
| `check.y` | 1289 | the seven property groups and the independent model |
| `modes.y` | 1031 | NORMAL/INSERT/VISUAL/COMMAND, the operator-pending state, the count, the `--keys` decoder |
| `screen.y` | 544 | the cell grid, the ANSI emitter, the plain emitter, `winsize()` |
| `editor.y` | 457 | CLI, the interactive loop, the scripted dump, `--bench` |
| `term.y` `args.y` `time.y` | 1871 | vendored, unedited |

4 789 lines of its own plus 1 871 vendored. Each header comment says what that
file is responsible for and which of the compiler's sharp edges it is shaped
around; the ones that are not obvious from reading the code are collected below.
Every module's `export` list is the surface actually reached from outside it —
nothing is exported "just in case".

### The one behaviour here that real vi does not have

```
$ ./editor --no-tty --keys 'gg' data/no-such-file.txt ; echo "exit $?"
editor: cannot read data/no-such-file.txt          <- stderr
exit 1                                             <- stdout is empty
```

**A file that was named and could not be read is an error, not an empty
buffer.** `vi` opens a new buffer and says `E484`; this program refuses and
exits 1, and it does so before it touches the terminal, so there is nothing to
restore. With **no** file named, `./editor --no-tty --keys 'gg'` is still a
normal new `[No Name]` buffer and exits 0 — the distinction is whether a path
was asked for, not whether the path worked.

The reason is the campaign's worst failure shape, and it was measured here
first. Before the fix, that same invocation printed an empty buffer, said

```
--- keys 96 of 96 ---
modified  no
```

and exited **0**: 96 keys "applied" to a buffer that held nothing, and a success
report built on top of a read that never happened. `fs.read_file` answers
`str?`, `none` for a path that is not there, and `none` is indistinguishable
from a legitimately empty file — so a discarded optional became an empty
buffer, and an empty buffer became a passing run. Two changes, both in the
brief:

* `buf.y`'s `load` handles the whole optional itself with the campaign's idiom
  (`is_some` decides, `unwrap` takes the value) and returns a plain `bool` that
  means what it says. The `none` arm still installs a one-empty-line buffer,
  because a screen has to draw something, but it does not pretend that is the
  file.
* `editor.y`'s `main` **honours** that `bool`. It did not: the verdict went
  into a local, an `E484` went into the message log where nobody reads it, and
  the run carried on.

The message goes to **stderr**, never stdout, because a runtime trap prints to
stdout and a message there corrupts a diff instead of announcing itself. And
nothing is dumped at all, so there are no golden bytes to mistake for a
result — the point is that a caller diffing stdout against `EXPECTED` gets an
empty file and a non-zero status, not a plausible-looking screen.

`check.y`'s group **(g)** runs this exact invocation, plus the same script with
the file present and with a script `:q!` cuts short, and asserts the three
things above. Reintroducing the old code makes it report 5 failures and exit 1.

---

## The compiler workarounds, and why each is here

Every one of these is a place where the shape of the code is a consequence of
how Y works. None of them is silent.

### 1. `read_key_timeout(0)`, never a non-zero one

`term.read_key_timeout(ms)` cannot be finer than 100 ms: `VTIME` counts
*deciseconds*, so any non-zero `ms` rounds **up** to the next 100 ms — measured at
about 104 ms per call. The frame loop polls with `read_key_timeout(0)`, which is a
real non-blocking poll (`VMIN=0`, `VTIME=0`) returning `KEY_NONE` at once, and
naps 6 ms when there is nothing to do. A `time.Pacer` is deliberately *not* used
here: an editor is event-driven, not frame-paced, and a frame is drawn because
something changed rather than because a timer fired.

### 2. `screen.winsize()` instead of `term.size()`

`term.size()` builds a **fresh `{rows, cols}` record on every call** — about 40
bytes, measured with `heap_used()`. An editor asks the window size once per
redraw to notice a resize, which makes it a 40-byte-per-frame leak with nothing
printed anywhere. `screen.winsize()` does the `TIOCGWINSZ` ioctl into a
module-level `[byte; 8]` and assigns two module-level `long`s, so it costs zero
allocations however often it runs. `term.y` is vendored unchanged and
`term.size()` is simply not on this path.

Nothing tells the program a `SIGWINCH` — Y has no signal handlers — so polling
the window size is the only way to notice one. `pty_test.py` proves it works by
growing the window mid-session and checking that the next frame paints into row
30.

### 3. `ord("x")` everywhere, never `'x'`

`'a'` is a **lexer error**; the character literal is `c'a'`
(`examples/BUGS.md`, "`'a'` is not a character literal"). Every key test here is
`ord("h")`, which needs no annotation and reads the same. There is no `s[i]`
byte in any of it either: indexing a `str` yields a `byte` and `str + byte`
**segfaults** (filed), so a key table is `ord()` calls and never a string of
characters indexed by the incoming key.

### 4. `key == term.KEY_ESC`, never `key == 27`

`term.read_key()` never answers `27`: a bare ESC is decoded to `KEY_ESC`, which
is 4096. Comparing against `27` works in a script whose `<Esc>` you wrote
yourself and **silently does nothing on a real terminal** — and "silently does
nothing" here means INSERT mode never ends, so every keystroke after an Escape
is inserted into the file. `modes.is_esc()` accepts both, with a comment saying
why. This was found by a `--no-tty` script that appended text after `<Esc>`; the
interactive path would have shown the same thing and the pty test now covers it.

### 5. `-> void` on every `def` that uses a bare `return;`

A `def` with no written return type takes it from the **end of its body**, so a
`return;` — a void expression — is rejected whenever the last statement produces
a value, and the message quotes that type: `error: 'return': expected long, got
void`. The `long` comes from a literal `0`; the source contains no `long`. Filed
as **"A bare `return;` is rejected with a message naming a type the source does
not contain"** in `examples/BUGS.md`; the workaround is `-> void`, which is on
every void helper in `buf.y` and `modes.y`.

### 6. Everything on a redraw path is a module-level fixed `[byte; N]`

The heap is an arena and nothing is ever freed. A literal inside a function body
allocates (`examples/SUGGESTIONS.md` item 7, measured at 64 B per array literal
per iteration), so `screen.y` keeps `CH`/`AT`/`GL`/`C0..C3`, the output buffer,
the plain buffer, the number scratch and the status-line scratch at module level.
Numbers are rendered by `num_to()` into a module-level buffer and copied —
**not** by `tostring()`, which allocates. String bytes are copied with
`byte_at(s, i)`, documented as no-copy, rather than through `s[i:]`. The status
line is assembled byte-at-a-time into one buffer, so there is no `str`
concatenation in the frame path.

Measured, `./editor --bench 5000 --rows R --cols C data/demo.txt`:

| geometry | heap | delta | bytes per redraw | rate |
|---|---|---|---|---|
| 12×44 | 717 504 → 717 504 | **0** | 792 | 125 000 fps |
| 24×80 | 717 504 → 717 504 | **0** | 2 502 | 45 000 fps |
| 60×200 (the grid's maximum) | 717 504 → 717 504 | **0** | 13 554 | 8 500 fps |

The heap total is *identical* at all three, and identical to the 12×44 run's
before the loop started, because every buffer on the frame path is a
module-level fixed array of the grid's maximum size. Nothing grows with the
terminal size and nothing grows with the frame count.

### 7. Guard-flag early exits, positive conditions instead of `continue`

Neither `break` nor `continue` exists (`ORCHESTRATOR.md` §2.9), so every early
exit is a `return` out of a small helper and every "skip this key" is a positive
`if` around the body. The dispatch is a chain of helpers rather than one long
`else`-chain because a helper can `return` and an `else`-branch cannot.

### 8. `winsize` clamps, and every index is proved

`byte_at(s, i)` traps out of bounds (`s[i:i+n]` clamps; `byte_at` does not), and
the trap prints on **stdout** — so a trap in a redraw corrupts the diff it is in
rather than announcing itself. `buf.y` proves `0 <= i <= len(line)` before every
index; `screen.winsize()` raises a zero-sized window to 3×20 and caps it at
60×200, because a pty from `pty.fork()` with nobody having set `TIOCSWINSZ`
reports 0×0 and a zero row would divide by nothing.

### 9. No closures on a hot path

A nested `def` is the natural way to share a dispatch table, but a closure
allocates and the C twin's value model has nowhere to put a function value. So
the dispatch is module-level state plus module-level functions, and the named-key
table in `modes.y` is a module-level literal on purpose — a record literal in a
loop body is 40 bytes an iteration.

### 10. Two `digits_of` functions on purpose

The gutter width is the digit count of the line count plus one, needed by
`buf.y` for the text area's width and by `screen.y` for the gutter. Three lines
is cheaper than a cross-module call on every redraw, and `check.y`'s (e) asserts
the two copies agree — which is the honest way to have a duplicated three-liner.

---

## Deliberate differences from vi

Listed so nothing here is a surprise, and so a reader does not mistake an
approximation for a bug:

* **`dw` never joins two lines.** A charwise operator range is clamped to the
  cursor's own line, so `d2w` on the last word of a line deletes that word and
  leaves the newline. Real vi's `d2w` joins. Clamping keeps `cw`, `yiw` and `dw`
  agreeing with each other, which is the property that actually bites a reader.
* **`/pattern` and `n` match a literal string.** There is no regex, in the editor
  and in the substitute. `\/` is honoured as an escaped delimiter, which is the
  one piece of vi's substitute syntax worth having — without it a URL cannot be
  substituted.
* **A tab is one column.** Real vi expands to the next multiple of 8. The trade
  is deliberate: identity between byte column and screen column is what makes the
  horizontal-scroll property checkable at all.
* **`:s/pat/rep` with no closing delimiter** reads a trailing run of `g`, `c`,
  `i` or `I` as flags — that is what makes `:s/a/b/g` work, which is how everyone
  writes it. The cost is that a replacement *ending* in one of those letters is
  read as flags (`s/a/big` means `bi` with flag `g`). The closing delimiter
  removes the ambiguity and `check.y` asserts both readings so neither can change
  silently.
* **A control byte is drawn `^X`**, in two cells, and takes no column of its own
  from the byte accounting — so a line with a tab shows `^I` rather than jumping
  the cursor.
* **`V` is linewise only.** No `v`.
* **Saving always ends the file with a newline**, as every text editor does, and
  a file that did not end with one gains it.
* **The undo history is capped at 128 entries.** `check.y` asserts the cap is
  exactly what it says it is, rather than letting it be discovered by an undo
  that stops early.

**`-W 1` notices: 90, all of one kind.** Every one is "the value of
`modes.feed()` is not used" -- a discarded call result. That is the intended
semantics of a mode machine whose return value the caller sometimes wants and
sometimes does not, and of a byte emitter. There are **zero** notices at the
default level, which is the bar. `-W 1` is above the bar by design -- another
example in this corpus (`fb.y`) produces 46 notices at `-W 1` of the same kind
-- so notices at `-W 1` are left alone rather than chased.

## What is not here

No regex, no `A` over a range (`:1,5s///`), no multi-file buffers, no `:e`, no
buffers or windows, no visual character mode, no syntax highlighting, no
search-offset (`/pat/e`), no `q` register. Each is a line or two away from what
is here; none is needed to make the example answer the questions it exists for.

---

## Bugs this example's own property check found

All four were in **this editor's** code, not in the compiler. They are listed
because that is the argument for having the check: `EXPECTED` reproduced all
four, byte for byte, with no warning.

1. **`buf.split_at` duplicated the tail instead of splitting.** It pushed the
   whole line and *then* the tail, so `Enter` on `epsilon` at column 7 gave
   `epsilon zeta` and a new ` zeta`. The model-vs-editor comparison is what
   noticed: the editor said `epsilon zeta`, the model said `epsilon`.
2. **`buf.snapb` indexed one past the end.** Clamping `k` to `len(s)` leaves it
   at `len(s)`, which is still out of range, and `byte_at` traps there.
   `check.y`'s (f) found it by asking for `snapb(s, 99)` on a 9-byte line — a
   question the rest of the program never asks and a reader would not spot.
3. **`set_mode(INSERT)` applied the *leave*-INSERT adjustment on entry.** It
   closed the undo block and stepped the cursor left, so `cawX` on `the lazy dog`
   produced `the lazXy` — the replacement typed one character before the word.
   **Every text comparison passed**: the text differs from what was intended, but
   the check was comparing against the editor's own behaviour. The fix came with
   four new assertions that compare the cursor's **column** as well as the text.
4. **The frame loop repainted unconditionally.** With nothing typed it drew
   ~166 frames a second forever. Not visible in any dump; the pty capture was
   618 KB instead of 3 KB, and the test now measures the frame count implicitly
   by how big the capture is.

Two more were found the same way but are worth one line each, because they are
the kind of thing that is easy to re-introduce:

* `modes.set_mode` keying the ESC handling on `27` (above), found because a
  `--no-tty` script appended text after `<Esc>`.
* `modes.script_decode` using `s.index_of(">")`, which searches from 0 — so a
  script with **two** `<name>` tokens made the first one's scan run on and
  swallow everything up to the second `>`. `index_of` has no `from` argument;
  `modes.find_byte_from` is the three-line replacement.

---

## Verification, as measured

Every process under `ulimit -S -v 3670016`, every run with `</dev/null`.

| check | result |
|---|---|
| compile with `refs/ycc.ref` | **8 files, zero warnings** |
| `./editor --check` | **1891 checks, 1891 ok, 0 failed**, exit 0, byte-identical over two runs, and identical for six seeds |
| `run=` line vs `EXPECTED` | **1616 B identical over two runs**, exit 0 |
| `python3 pty_test.py` | **27 ok, 0 failed** |
| `python3 ../gate.py editor` | **9/9 passed**, including item 0 (the pin) and item 8 (this folder's own property check) |
| `--bench 5000` at 12×44 / 24×80 / 60×200 | `heap 717504 -> 717504  delta 0` at **all three**; 792 / 2 502 / 13 554 bytes per frame; 125 000 / 45 000 / 8 500 fps |
| error and argument paths | 36 invocations — `--help --version --bogus -Z --rows 0/3/61/abc --cols 11/201/x --keys (missing value, unknown name, unterminated `<`, bare `<Esc`) --no-tty with no keys --keys without --no-tty --bench 0/-1/99999999/abc a missing file two operands a reversed substitute a text object with no closing quote a whole screen of operators at once a 250x500 window `:w /nonexistent-dir/x` `:q` `:wq` `999999G<Esc>dd` — **0 traps**, every bad path exits 1 or 2 with a specific message on stderr |
| the screen, read by a human | rendered from `golden/pty-capture.txt` with a small emulator: gutter, `^I`, UTF-8, `~` below the end, the typed text, `:q!` on the command line — all correct |
| self-contained | a fresh copy of this folder alone, with `refs/` the only other thing present, builds, passes all 1891 checks, reproduces `EXPECTED` **byte for byte**, rewrites `golden/demo-written.txt` identically, and passes all 27 pty checks. No cross-folder `import` or `embed`. |

**What a golden file could not have caught**, had this README been the only
evidence: bugs 1–4 above, the `hcol` minimality property in (e), the
`caw`/`diw`/`ci"` ranges in (c), and the substitute counts in (b). That is the
whole reason `check.y` exists, and why `gate.py` item 8 runs it.
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

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
